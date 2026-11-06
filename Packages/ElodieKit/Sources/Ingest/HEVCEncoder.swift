import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

/// How the encoder spends bits.
public enum EncoderRate: Sendable, Equatable, CustomStringConvertible {
    /// A constant quality from 0 to 1.
    case quality(Float)
    /// An average number of bits per pixel per frame.
    case bitsPerPixel(Double)

    public var description: String {
        switch self {
        case .quality(let value): "quality \(value)"
        case .bitsPerPixel(let value): "\(value) bits per pixel"
        }
    }
}

public struct EncoderSettings: Sendable {
    public var width: Int
    public var height: Int
    /// The longest run of frames between keyframes. Backward scrubbing has to
    /// decode from a keyframe, so this is what limits how fast seeking can be.
    public var keyframeInterval: Int
    public var rate: EncoderRate

    public init(width: Int, height: Int, keyframeInterval: Int = 30, rate: EncoderRate) {
        self.width = width
        self.height = height
        self.keyframeInterval = keyframeInterval
        self.rate = rate
    }
}

public enum EncoderError: Error {
    case session(OSStatus)
    case property(String, OSStatus)
    case encode(OSStatus)
    case noData
}

/// One encoded frame.
public struct EncodedFrame: Sendable {
    /// Length-prefixed NAL units.
    public var data: Data
    /// The codec's parameter sets (`hvcC`).
    public var parameterSets: Data
    public var isKeyframe: Bool
}

/// Encodes screen frames to HEVC in hardware.
///
/// Frames are presented at a fixed 30 per second regardless of when they were
/// captured. Their real times live in the database, and this is what makes the
/// bitrate mean "bits per stored frame".
public final class HEVCEncoder {
    /// Frames are spaced this far apart in the bitstream.
    private static let timescale: Int32 = 30

    private let session: VTCompressionSession
    private var frameIndex: Int64 = 0

    public init(settings: EncoderSettings) throws {
        var created: VTCompressionSession?
        let specification = [
            kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: true,
        ] as CFDictionary
        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: Int32(settings.width),
            height: Int32(settings.height),
            codecType: kCMVideoCodecType_HEVC,
            encoderSpecification: specification,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: nil,
            refcon: nil,
            compressionSessionOut: &created
        )
        guard status == noErr, let created else {
            throw EncoderError.session(status)
        }
        session = created

        func set(_ key: CFString, _ value: CFTypeRef) throws {
            let status = VTSessionSetProperty(session, key: key, value: value)
            guard status == noErr else {
                throw EncoderError.property(key as String, status)
            }
        }

        try set(kVTCompressionPropertyKey_RealTime, kCFBooleanFalse)
        try set(kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_HEVC_Main_AutoLevel)
        // No reordering means decode order is display order, which keeps seeking
        // simple. The hardware encoder doesn't support MaxFrameDelayCount, so use
        // `finish()` after a frame when it must come out immediately.
        try set(kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse)
        try set(kVTCompressionPropertyKey_MaxKeyFrameInterval, settings.keyframeInterval as CFNumber)

        switch settings.rate {
        case .quality(let quality):
            try set(kVTCompressionPropertyKey_Quality, quality as CFNumber)
        case .bitsPerPixel(let bits):
            let bitsPerSecond = Double(settings.width * settings.height * Int(Self.timescale)) * bits
            try set(kVTCompressionPropertyKey_AverageBitRate, Int(bitsPerSecond) as CFNumber)
        }

        // Frames are captured in display P3 with the sRGB curve, and these tags
        // tell the decoder and compositor so.
        try set(kVTCompressionPropertyKey_ColorPrimaries, kCMFormatDescriptionColorPrimaries_P3_D65)
        try set(kVTCompressionPropertyKey_TransferFunction, kCMFormatDescriptionTransferFunction_sRGB)
        try set(kVTCompressionPropertyKey_YCbCrMatrix, kCMFormatDescriptionYCbCrMatrix_ITU_R_709_2)

        let prepared = VTCompressionSessionPrepareToEncodeFrames(session)
        guard prepared == noErr else {
            throw EncoderError.session(prepared)
        }
    }

    deinit {
        VTCompressionSessionInvalidate(session)
    }

    /// Encodes a frame. `completion` runs once for it, on an encoder thread.
    public func encode(
        _ pixelBuffer: CVPixelBuffer,
        forceKeyframe: Bool = false,
        completion: @escaping @Sendable (Result<EncodedFrame, any Error>) -> Void
    ) {
        let timestamp = CMTime(value: frameIndex, timescale: Self.timescale)
        frameIndex += 1
        let properties: CFDictionary? = forceKeyframe
            ? [kVTEncodeFrameOptionKey_ForceKeyFrame: kCFBooleanTrue] as CFDictionary
            : nil

        let status = VTCompressionSessionEncodeFrame(
            session,
            imageBuffer: pixelBuffer,
            presentationTimeStamp: timestamp,
            duration: CMTime(value: 1, timescale: Self.timescale),
            frameProperties: properties,
            infoFlagsOut: nil
        ) { status, _, sampleBuffer in
            guard status == noErr else {
                completion(.failure(EncoderError.encode(status)))
                return
            }
            guard let sampleBuffer, let frame = Self.extract(sampleBuffer) else {
                completion(.failure(EncoderError.noData))
                return
            }
            completion(.success(frame))
        }
        if status != noErr {
            completion(.failure(EncoderError.encode(status)))
        }
    }

    /// Waits for frames already submitted to come out.
    public func finish() throws {
        let status = VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
        guard status == noErr else {
            throw EncoderError.encode(status)
        }
    }

    private static func extract(_ sampleBuffer: CMSampleBuffer) -> EncodedFrame? {
        guard let block = CMSampleBufferGetDataBuffer(sampleBuffer),
              let format = CMSampleBufferGetFormatDescription(sampleBuffer),
              let parameterSets = parameterSets(of: format)
        else {
            return nil
        }
        let length = CMBlockBufferGetDataLength(block)
        var data = Data(count: length)
        let status = data.withUnsafeMutableBytes { bytes in
            CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: bytes.baseAddress!)
        }
        guard status == kCMBlockBufferNoErr else {
            return nil
        }

        var isKeyframe = true
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
            as? [[CFString: Any]], let first = attachments.first {
            isKeyframe = (first[kCMSampleAttachmentKey_NotSync] as? Bool) != true
        }
        return EncodedFrame(data: data, parameterSets: parameterSets, isKeyframe: isKeyframe)
    }

    private static func parameterSets(of format: CMFormatDescription) -> Data? {
        let extensions = CMFormatDescriptionGetExtensions(format) as? [CFString: Any]
        let atoms = extensions?[kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms] as? [String: Any]
        return atoms?["hvcC"] as? Data
    }
}
