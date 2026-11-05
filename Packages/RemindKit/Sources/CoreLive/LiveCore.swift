import CoreABI
import CoreAPI
import Foundation

/// `RemindCore` backed by the Rust library.
public final class LiveCore: RemindCore {
    private let core: Core

    /// Opens a vault, recovering from any crash. Don't call this on the main thread.
    public init(vaultDirectory: URL, masterKey: Data) throws {
        core = try Core.open(root: vaultDirectory.path, masterKey: masterKey)
    }

    public func info() throws -> CoreAPI.CoreInfo {
        let info = try core.info()
        return CoreAPI.CoreInfo(
            version: info.version,
            sqliteVersion: info.sqliteVersion,
            cipherProvider: info.cipherProvider
        )
    }

    public func stats() -> CoreAPI.CoreStats {
        let stats = core.stats()
        return CoreAPI.CoreStats(
            loggedFrames: stats.loggedFrames,
            indexedFrames: stats.indexedFrames,
            droppedFrames: stats.droppedFrames,
            appendFailures: stats.appendFailures,
            isDiskFull: stats.diskFull
        )
    }

    public func append(_ sample: EncodedSample) throws -> CoreAPI.AppendOutcome {
        let outcome = try core.appendSample(sample: SampleInput(
            displayUuid: sample.displayID.data,
            width: UInt32(sample.width),
            height: UInt32(sample.height),
            parameterSets: sample.parameterSets,
            wallMs: sample.capturedAt.milliseconds,
            monoNs: sample.monotonicNanoseconds,
            isSync: sample.isKeyframe,
            bundleId: sample.context.bundleID,
            window: sample.context.window,
            url: sample.context.url,
            profile: sample.context.profile,
            data: sample.data
        ))
        switch outcome {
        case .accepted: return .accepted
        case .droppedQueueFull: return .droppedQueueFull
        case .needsKeyframe: return .needsKeyframe
        }
    }

    public func sealAll() throws {
        try core.sealAll()
    }

    public func lookup(display: UUID, at time: Date) throws -> CoreAPI.FrameRef? {
        try core.lookup(displayUuid: display.data, tMs: time.milliseconds).map {
            CoreAPI.FrameRef(id: $0.id, capturedAt: Date(milliseconds: $0.tMs))
        }
    }

    public func readGroup(containing frameID: Int64) throws -> GroupOfPictures {
        let gop = try core.readGop(frameId: frameID)
        return GroupOfPictures(
            width: Int(gop.width),
            height: Int(gop.height),
            parameterSets: gop.parameterSets,
            samples: gop.samples.map {
                GroupOfPictures.Sample(
                    frameID: $0.frameId,
                    capturedAt: Date(milliseconds: $0.tMs),
                    isKeyframe: $0.isSync,
                    data: $0.data
                )
            },
            target: Int(gop.target)
        )
    }
}

extension UUID {
    var data: Data {
        withUnsafeBytes(of: uuid) { Data($0) }
    }
}

extension Date {
    var milliseconds: Int64 {
        Int64((timeIntervalSince1970 * 1000).rounded())
    }

    init(milliseconds: Int64) {
        self.init(timeIntervalSince1970: Double(milliseconds) / 1000)
    }
}
