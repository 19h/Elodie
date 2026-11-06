import AVFoundation
import CoreAPI
import CoreMedia
import Foundation

public enum ExportError: Error, Equatable {
    case nothingRecorded
    case cannotWrite(String)
}

/// What came out of an export.
public struct ExportSummary: Sendable, Equatable {
    /// How many frames the video plays.
    public var frames: Int
    /// Set when the clip had to stop before the end of the stretch, because the display's mode
    /// changed and one video track can't hold both.
    public var stoppedEarlyAt: Date?
}

/// Exports a stretch of recording as an ordinary video file.
///
/// Recordings stay encrypted in the vault, so this is the one way to get a clip out, and
/// only when someone asks. The video isn't re-encoded, so it's quick and loses nothing.
/// The clip plays at real time, since each frame stays up until the next was captured, except
/// for long gaps, which would otherwise be minutes of nothing.
public enum MP4Exporter {
    /// Frames are only stored when the screen changes, so up to this long is just a still
    /// screen. Past it, the clip moves on after `heldGap`.
    static let longestStill: TimeInterval = 60
    static let heldGap: TimeInterval = 1

    /// How long a frame stays up, given how long it was until the next one.
    static func onScreenTime(forGap gap: TimeInterval) -> TimeInterval {
        gap > longestStill ? heldGap : max(gap, 1.0 / 60)
    }

    /// Exports what was on a display from one time to another.
    ///
    /// A video can only start on a keyframe, so the file also holds the frames from the
    /// keyframe up to the start. They're marked as not to be played, so no player shows them.
    /// The existing file at `url` is only replaced once the new one is complete.
    @discardableResult
    public static func export(
        core: any ElodieCore,
        display: UUID,
        from: Date,
        to: Date,
        to url: URL
    ) async throws -> ExportSummary {
        guard let first = try firstFrame(core: core, display: display, from: from, to: to) else {
            throw ExportError.nothingRecorded
        }

        let partial = url.deletingLastPathComponent().appending(path: ".\(UUID().uuidString).partial.mp4")
        do {
            let summary = try await write(core: core, startingAt: first, from: from, to: to, to: partial)
            if FileManager.default.fileExists(atPath: url.path) {
                _ = try FileManager.default.replaceItemAt(url, withItemAt: partial)
            } else {
                try FileManager.default.moveItem(at: partial, to: url)
            }
            return summary
        } catch {
            try? FileManager.default.removeItem(at: partial)
            throw error
        }
    }

    /// What was on screen at `from`: the last frame before it, or if that's so long ago that
    /// recording must have stopped, the first one after it.
    private static func firstFrame(core: any ElodieCore, display: UUID, from: Date, to: Date) throws -> FrameRef? {
        if let before = try core.lookup(display: display, at: from) {
            if from.timeIntervalSince(before.capturedAt) <= longestStill { return before }
            guard let next = try core.neighbour(of: before.id, forward: true), next.capturedAt <= to else { return nil }
            return next
        }
        // Nothing before the start at all, so walk back from the end of the stretch.
        guard var current = try core.lookup(display: display, at: to) else { return nil }
        while let previous = try core.neighbour(of: current.id, forward: false), previous.capturedAt >= from {
            current = previous
        }
        return current.capturedAt >= from ? current : nil
    }

    private static func write(
        core: any ElodieCore,
        startingAt first: FrameRef,
        from: Date,
        to: Date,
        to url: URL
    ) async throws -> ExportSummary {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        var input: AVAssetWriterInput?
        var format: CMVideoFormatDescription?
        var parameterSets: Data?
        var frames = 0
        var stoppedEarlyAt: Date?
        var nextFrame: Int64? = first.id
        var pending: GroupOfPictures.Sample?
        // Where the next frame goes in the video. Frames before the start come first, a tiny
        // moment each, and the playable part begins after them.
        var clock: TimeInterval = 0

        func append(_ sample: GroupOfPictures.Sample, duration: TimeInterval) async throws {
            guard let input, let format else { return }
            let buffer = try makeSampleBuffer(
                sample.data,
                format: format,
                time: clock,
                duration: duration,
                isKeyframe: sample.isKeyframe
            )
            clock += duration
            while !input.isReadyForMoreMediaData {
                try await Task.sleep(for: .milliseconds(5))
            }
            if !input.append(buffer) {
                throw ExportError.cannotWrite(writer.error?.localizedDescription ?? "unknown")
            }
        }

        scanning: while let frameID = nextFrame {
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
                input = created
                // Everything up to the frame this starts on is only there so it can decode.
                // The session starts after them, which is what keeps them from being played.
                let lead = group.samples.prefix { $0.frameID != first.id }
                writer.startSession(atSourceTime: CMTime(value: CMTimeValue(lead.count), timescale: 600))
                for sample in lead {
                    try await append(sample, duration: 1.0 / 600)
                }
            }
            // A new display mode changes the picture format, and one track can't hold
            // both, so the clip ends there.
            if group.parameterSets != parameterSets {
                stoppedEarlyAt = group.samples.first?.capturedAt
                break
            }

            for sample in group.samples {
                if sample.capturedAt > to { break scanning }
                if pending == nil, sample.frameID != first.id, frames == 0 { continue }
                if let previous = pending {
                    // The first frame only counts from the start of the stretch.
                    let shownFrom = frames == 0 ? max(previous.capturedAt, from) : previous.capturedAt
                    try await append(previous, duration: onScreenTime(forGap: sample.capturedAt.timeIntervalSince(shownFrom)))
                    frames += 1
                }
                pending = sample
            }
            guard let last = group.samples.last else { break }
            nextFrame = try core.neighbour(of: last.frameID, forward: true)?.id
        }

        if let pending {
            // The screen stayed like this until the end of the stretch, or the next frame.
            let shownFrom = frames == 0 ? max(pending.capturedAt, from) : pending.capturedAt
            let end = stoppedEarlyAt ?? to
            try await append(pending, duration: max(onScreenTime(forGap: end.timeIntervalSince(shownFrom)), heldGap))
            frames += 1
        }
        guard frames > 0, let input else {
            writer.cancelWriting()
            throw ExportError.nothingRecorded
        }
        input.markAsFinished()
        await writer.finishWriting()
        if writer.status != .completed {
            throw ExportError.cannotWrite(writer.error?.localizedDescription ?? "unknown")
        }
        return ExportSummary(frames: frames, stoppedEarlyAt: stoppedEarlyAt)
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
        duration: TimeInterval,
        isKeyframe: Bool
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
        // Unmarked samples all count as keyframes, and seeking in the file would show garbage.
        if !isKeyframe,
           let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0 {
            let entry = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(
                entry,
                Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque(),
                Unmanaged.passUnretained(kCFBooleanTrue).toOpaque()
            )
        }
        return sample
    }
}
