import AVFoundation
import CoreAPI
import CoreMedia
import Foundation

public enum ExportError: Error, Equatable {
    case nothingRecorded
    case cannotWrite(String)
}

/// Exports a stretch of recording as an ordinary video file.
///
/// Recordings stay encrypted in the vault, so this is the one way to get a clip out, and
/// only when someone asks. The video isn't re-encoded, so it's quick and loses nothing.
/// The clip plays at real time: each frame stays up until the next was captured.
public enum MP4Exporter {
    /// Exports frames on a display from one time to another. A clip can't start on a
    /// frame that needs earlier ones, so it starts at the keyframe before `from`.
    ///
    /// - Returns: how many frames were written.
    @discardableResult
    public static func export(
        core: any RemindCore,
        display: UUID,
        from: Date,
        to: Date,
        to url: URL
    ) async throws -> Int {
        guard let first = try core.lookup(display: display, at: from) ?? core.neighbour(after: from, display: display) else {
            throw ExportError.nothingRecorded
        }

        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        var input: AVAssetWriterInput?
        var format: CMVideoFormatDescription?
        var parameterSets: Data?
        var frames = 0
        var start: Date?
        var nextFrame: Int64? = first.id
        var pending: (data: Data, time: Date)?

        func write(_ sample: (data: Data, time: Date), until end: Date) async throws {
            guard let input, let format, let start else { return }
            let buffer = try makeSampleBuffer(
                sample.data,
                format: format,
                time: sample.time.timeIntervalSince(start),
                // Every frame lasts until the next, so a still screen stays still.
                duration: max(end.timeIntervalSince(sample.time), 1.0 / 60)
            )
            while !input.isReadyForMoreMediaData {
                try await Task.sleep(for: .milliseconds(5))
            }
            if !input.append(buffer) {
                throw ExportError.cannotWrite(writer.error?.localizedDescription ?? "unknown")
            }
            frames += 1
        }

        while let frameID = nextFrame {
            let group = try core.readGroup(containing: frameID)
            if input == nil {
                format = try makeFormat(parameterSets: group.parameterSets, width: group.width, height: group.height)
                parameterSets = group.parameterSets
                let created = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: format)
                created.expectsMediaDataInRealTime = false
                guard writer.canAdd(created) else {
                    throw ExportError.cannotWrite("the video couldn't be added")
                }
                writer.add(created)
                guard writer.startWriting() else {
                    throw ExportError.cannotWrite(writer.error?.localizedDescription ?? "unknown")
                }
                writer.startSession(atSourceTime: .zero)
                input = created
                start = group.samples.first?.capturedAt
            }
            // A new display mode changes the picture format, and one track can't hold
            // both, so the clip ends there.
            if group.parameterSets != parameterSets { break }

            var passedEnd = false
            for sample in group.samples {
                if sample.capturedAt > to {
                    passedEnd = true
                    break
                }
                if let previous = pending {
                    try await write(previous, until: sample.capturedAt)
                }
                pending = (sample.data, sample.capturedAt)
            }
            if passedEnd { break }
            guard let last = group.samples.last else { break }
            nextFrame = try core.neighbour(of: last.frameID, forward: true)?.id
        }

        if let pending {
            try await write(pending, until: max(to, pending.time.addingTimeInterval(2)))
        }
        guard frames > 0, let input else {
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: url)
            throw ExportError.nothingRecorded
        }
        input.markAsFinished()
        await writer.finishWriting()
        if writer.status != .completed {
            throw ExportError.cannotWrite(writer.error?.localizedDescription ?? "unknown")
        }
        return frames
    }

    private static func makeFormat(parameterSets: Data, width: Int, height: Int) throws -> CMVideoFormatDescription {
        var format: CMVideoFormatDescription?
        let extensions: [CFString: Any] = [
            kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms: ["hvcC": parameterSets],
        ]
        let status = CMVideoFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            codecType: kCMVideoCodecType_HEVC,
            width: Int32(width),
            height: Int32(height),
            extensions: extensions as CFDictionary,
            formatDescriptionOut: &format
        )
        guard status == noErr, let format else {
            throw ExportError.cannotWrite("the picture format wasn't valid (\(status))")
        }
        return format
    }

    private static func makeSampleBuffer(
        _ data: Data,
        format: CMVideoFormatDescription,
        time: TimeInterval,
        duration: TimeInterval
    ) throws -> CMSampleBuffer {
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
        guard status == noErr, let block else { throw ExportError.cannotWrite("out of memory") }
        status = data.withUnsafeBytes {
            CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: data.count)
        }
        guard status == noErr else { throw ExportError.cannotWrite("out of memory") }

        var timing = CMSampleTimingInfo(
            duration: CMTime(seconds: duration, preferredTimescale: 600),
            presentationTimeStamp: CMTime(seconds: time, preferredTimescale: 600),
            decodeTimeStamp: .invalid
        )
        var size = data.count
        var sample: CMSampleBuffer?
        status = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: block,
            formatDescription: format,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &size,
            sampleBufferOut: &sample
        )
        guard status == noErr, let sample else { throw ExportError.cannotWrite("the frame wasn't valid") }
        return sample
    }
}

private extension RemindCore {
    /// The first frame at or after a time, for a clip that starts before anything was
    /// recorded.
    func neighbour(after time: Date, display: UUID) throws -> FrameRef? {
        guard let latest = try lookup(display: display, at: .distantFuture) else { return nil }
        var current = latest
        // Walk back from the latest, which is short in practice: clips are recent.
        while let previous = try neighbour(of: current.id, forward: false), previous.capturedAt >= time {
            current = previous
        }
        return current.capturedAt >= time ? current : nil
    }
}
