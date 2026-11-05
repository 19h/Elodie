import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

public enum DecoderError: Error {
    case format(OSStatus)
    case session(OSStatus)
    case sample(OSStatus)
    case decode(OSStatus)
    case noImage
}

/// Decodes samples read back from the log, one at a time, into IOSurface-backed
/// pixel buffers that can be shown without copying.
public final class HEVCDecoder {
    private let session: VTDecompressionSession
    private let format: CMVideoFormatDescription

    public init(parameterSets: Data, width: Int, height: Int) throws {
        let extensions: [CFString: Any] = [
            kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms: ["hvcC": parameterSets],
        ]
        var format: CMVideoFormatDescription?
        let formatStatus = CMVideoFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            codecType: kCMVideoCodecType_HEVC,
            width: Int32(width),
            height: Int32(height),
            extensions: extensions as CFDictionary,
            formatDescriptionOut: &format
        )
        guard formatStatus == noErr, let format else {
            throw DecoderError.format(formatStatus)
        }
        self.format = format

        let attributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
            kCVPixelBufferIOSurfacePropertiesKey: [String: Any](),
            kCVPixelBufferMetalCompatibilityKey: true,
        ]
        var session: VTDecompressionSession?
        let sessionStatus = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            formatDescription: format,
            decoderSpecification: nil,
            imageBufferAttributes: attributes as CFDictionary,
            outputCallback: nil,
            decompressionSessionOut: &session
        )
        guard sessionStatus == noErr, let session else {
            throw DecoderError.session(sessionStatus)
        }
        self.session = session
    }

    deinit {
        VTDecompressionSessionInvalidate(session)
    }

    /// Decodes one sample. P-frames need every earlier frame since the last
    /// keyframe to have gone through this decoder first.
    public func decode(_ data: Data) throws -> CVPixelBuffer {
        let sample = try makeSampleBuffer(data)
        nonisolated(unsafe) var result: CVPixelBuffer?
        nonisolated(unsafe) var failure: OSStatus = noErr
        // Without the asynchronous flag, the handler runs before this returns.
        let status = VTDecompressionSessionDecodeFrame(
            session,
            sampleBuffer: sample,
            flags: [],
            infoFlagsOut: nil
        ) { status, _, image, _, _ in
            failure = status
            result = image
        }
        guard status == noErr, failure == noErr else {
            throw DecoderError.decode(status != noErr ? status : failure)
        }
        guard let result else {
            throw DecoderError.noImage
        }
        return result
    }

    private func makeSampleBuffer(_ data: Data) throws -> CMSampleBuffer {
        var block: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: data.count,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: data.count,
            flags: kCMBlockBufferAssureMemoryNowFlag,
            blockBufferOut: &block
        )
        guard status == noErr, let block else {
            throw DecoderError.sample(status)
        }
        status = data.withUnsafeBytes { bytes in
            CMBlockBufferReplaceDataBytes(
                with: bytes.baseAddress!,
                blockBuffer: block,
                offsetIntoDestination: 0,
                dataLength: data.count
            )
        }
        guard status == noErr else {
            throw DecoderError.sample(status)
        }

        var sample: CMSampleBuffer?
        var size = data.count
        status = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: block,
            formatDescription: format,
            sampleCount: 1,
            sampleTimingEntryCount: 0,
            sampleTimingArray: nil,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &size,
            sampleBufferOut: &sample
        )
        guard status == noErr, let sample else {
            throw DecoderError.sample(status)
        }
        return sample
    }
}
