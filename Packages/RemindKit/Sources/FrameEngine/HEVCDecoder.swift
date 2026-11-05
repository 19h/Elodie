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

    /// Decodes samples in order and returns their pictures, leaving out any it stopped before.
    /// The hardware works on several at once this way, which takes about a third less time
    /// than waiting for each in turn: 31 ms against 45 ms for a group of 30.
    ///
    /// - Parameter shouldStop: asked before each sample, and nothing more starts once it's true.
    public func decode(_ samples: [Data], shouldStop: () -> Bool = { false }) throws -> [CVPixelBuffer] {
        let results = BatchResults(count: samples.count)
        var submitted = 0
        for (index, data) in samples.enumerated() {
            if shouldStop() { break }
            let sample = try makeSampleBuffer(data)
            let status = VTDecompressionSessionDecodeFrame(
                session,
                sampleBuffer: sample,
                flags: [._EnableAsynchronousDecompression],
                infoFlagsOut: nil
            ) { status, _, image, _, _ in
                results.set(index, status: status, image: image)
            }
            guard status == noErr else {
                VTDecompressionSessionWaitForAsynchronousFrames(session)
                throw DecoderError.decode(status)
            }
            submitted += 1
        }
        VTDecompressionSessionWaitForAsynchronousFrames(session)
        return try results.pictures(upTo: submitted)
    }

    /// Where pictures land as they finish, on whatever thread that happens on.
    private final class BatchResults: @unchecked Sendable {
        private let lock = NSLock()
        private var images: [CVPixelBuffer?]
        private var failure: OSStatus = noErr

        init(count: Int) {
            images = Array(repeating: nil, count: count)
        }

        func set(_ index: Int, status: OSStatus, image: CVImageBuffer?) {
            lock.withLock {
                images[index] = image
                if status != noErr { failure = status }
            }
        }

        func pictures(upTo count: Int) throws -> [CVPixelBuffer] {
            try lock.withLock {
                guard failure == noErr else { throw DecoderError.decode(failure) }
                return try images.prefix(count).map { image in
                    guard let image else { throw DecoderError.noImage }
                    return image
                }
            }
        }
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
