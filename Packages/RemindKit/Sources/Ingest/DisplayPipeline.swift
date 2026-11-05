import Capture
import CoreAPI
import CoreVideo
import Foundation

/// What to do with a frame that has changed enough to keep.
public enum FrameDecision: Sendable, Equatable {
    case keep(FrameContext)
    case drop(reason: String)
}

/// Counts of what happened to each frame. Everything received ends up in exactly
/// one of the other buckets, or is still in progress.
public struct PipelineStats: Sendable, Equatable {
    public var received = 0
    public var busy = 0
    public var unchanged = 0
    public var black = 0
    public var excluded = 0
    public var encodeFailed = 0
    public var appendRefused = 0
    public var stored = 0

    public init() {}
}

public struct PipelineSettings: Sendable {
    /// A frame needs this many changed pixels to be kept.
    public var changedPixelThreshold = 1000
    public var keyframeInterval = 30
    public var rate = EncoderRate.quality(0.75)

    public init() {}
}

/// Turns one display's frames into encoded samples in the vault.
///
/// Everything runs on one serial queue, and nothing blocks it: the GPU and encoder
/// call back when they're done. Each frame is one of the capture stream's few
/// buffers, so it's held only until the encoder has it.
public final class DisplayPipeline: @unchecked Sendable {
    /// Frames allowed inside the encoder at once. More than this means the machine
    /// can't keep up, so it's better to drop before encoding.
    private static let maxEncoding = 2

    public let queue: DispatchQueue
    private let core: any RemindCore
    private let displayUUID: UUID
    private let settings: PipelineSettings
    private let decide: @Sendable (CapturedFrame) -> FrameDecision
    private let differ: FrameDiffer

    private var encoder: HEVCEncoder?
    private var encoderSize: (width: Int, height: Int)?
    private var comparing = false
    private var encoding = 0
    private var needsKeyframe = true
    private var starNext = false
    private var counters = PipelineStats()

    public init(
        core: any RemindCore,
        displayUUID: UUID,
        settings: PipelineSettings = PipelineSettings(),
        decide: @escaping @Sendable (CapturedFrame) -> FrameDecision
    ) throws {
        self.core = core
        self.displayUUID = displayUUID
        self.settings = settings
        self.decide = decide
        differ = try FrameDiffer()
        queue = DispatchQueue(label: "remind.display.\(displayUUID.uuidString)", qos: .utility)
    }

    public var stats: PipelineStats {
        queue.sync { counters }
    }

    /// Keeps the next frame even if it hasn't changed.
    public func keepNextFrame() {
        queue.async { self.starNext = true }
    }

    /// Takes a frame. Must be called on `queue`.
    public func ingest(_ frame: CapturedFrame) {
        dispatchPrecondition(condition: .onQueue(queue))
        counters.received += 1

        // Dropping here means the next frame still compares against what's stored,
        // so a change isn't lost, only delayed.
        guard !comparing, encoding < Self.maxEncoding else {
            counters.busy += 1
            return
        }

        comparing = true
        differ.compare(frame.pixelBuffer, ignoringTop: frame.menuBarRows) { [self] result in
            queue.async { self.finishComparison(frame, result) }
        }
    }

    private func finishComparison(_ frame: CapturedFrame, _ result: Result<FrameDifference, any Error>) {
        comparing = false
        let forced = starNext

        switch result {
        case .failure:
            // Without a comparison it's safest to keep the frame. Storing an
            // extra frame costs little, and missing one can't be undone.
            break
        case .success(let difference):
            if difference.isBlack {
                counters.black += 1
                return
            }
            if !difference.isFirstFrame, !forced, difference.changedPixels < settings.changedPixelThreshold {
                counters.unchanged += 1
                return
            }
        }

        switch decide(frame) {
        case .drop:
            // The reference stays put, so this change is still noticed next time.
            counters.excluded += 1
        case .keep(let context):
            starNext = false
            differ.commitCandidate()
            encode(frame, context: context)
        }
    }

    private func encode(_ frame: CapturedFrame, context: FrameContext) {
        let width = CVPixelBufferGetWidth(frame.pixelBuffer)
        let height = CVPixelBufferGetHeight(frame.pixelBuffer)
        do {
            let encoder = try encoder(width: width, height: height)
            encoding += 1
            let force = needsKeyframe
            needsKeyframe = false
            encoder.encode(frame.pixelBuffer, forceKeyframe: force) { [self] result in
                queue.async {
                    self.finishEncoding(result, frame: frame, width: width, height: height, context: context)
                }
            }
        } catch {
            counters.encodeFailed += 1
            needsKeyframe = true
        }
    }

    private func encoder(width: Int, height: Int) throws -> HEVCEncoder {
        if let encoder, encoderSize?.width == width, encoderSize?.height == height {
            return encoder
        }
        let created = try HEVCEncoder(settings: EncoderSettings(
            width: width,
            height: height,
            keyframeInterval: settings.keyframeInterval,
            rate: settings.rate
        ))
        encoder = created
        encoderSize = (width, height)
        needsKeyframe = true
        return created
    }

    private func finishEncoding(
        _ result: Result<EncodedFrame, any Error>,
        frame: CapturedFrame,
        width: Int,
        height: Int,
        context: FrameContext
    ) {
        encoding -= 1
        guard case .success(let encoded) = result else {
            counters.encodeFailed += 1
            // The chain is broken, and the encoder may be unwell.
            needsKeyframe = true
            encoder = nil
            encoderSize = nil
            return
        }
        do {
            let outcome = try core.append(EncodedSample(
                displayID: displayUUID,
                width: width,
                height: height,
                parameterSets: encoded.parameterSets,
                capturedAt: frame.capturedAt,
                monotonicNanoseconds: DispatchTime.now().uptimeNanoseconds,
                isKeyframe: encoded.isKeyframe,
                context: context,
                data: encoded.data
            ))
            switch outcome {
            case .accepted:
                counters.stored += 1
            case .droppedQueueFull, .needsKeyframe:
                counters.appendRefused += 1
                needsKeyframe = true
            }
        } catch {
            counters.appendRefused += 1
            needsKeyframe = true
        }
    }
}
