import CoreAPI
import Foundation

/// `RemindCore` for previews and tests. It keeps samples in memory.
public final class FakeCore: RemindCore, @unchecked Sendable {
    private let lock = NSLock()
    private var samples: [EncodedSample] = []

    public init() {}

    public func info() throws -> CoreInfo {
        CoreInfo(version: "fake", sqliteVersion: "fake", cipherProvider: "fake")
    }

    public func stats() -> CoreStats {
        lock.withLock {
            let count = UInt64(samples.count)
            return CoreStats(loggedFrames: count, indexedFrames: count, droppedFrames: 0, appendFailures: 0, isDiskFull: false)
        }
    }

    public func append(_ sample: EncodedSample) throws -> AppendOutcome {
        lock.withLock { samples.append(sample) }
        return .accepted
    }

    public func sealAll() throws {}

    public func lookup(display: UUID, at time: Date) throws -> FrameRef? {
        lock.withLock {
            guard let index = samples.lastIndex(where: { $0.displayID == display && $0.capturedAt <= time }) else {
                return nil
            }
            return FrameRef(id: Int64(index), capturedAt: samples[index].capturedAt)
        }
    }

    public func readGroup(containing frameID: Int64) throws -> GroupOfPictures {
        try lock.withLock {
            let index = Int(frameID)
            guard samples.indices.contains(index) else {
                throw CocoaError(.fileNoSuchFile)
            }
            let start = samples[...index].lastIndex(where: \.isKeyframe) ?? 0
            let end = samples[(index + 1)...].firstIndex(where: \.isKeyframe) ?? samples.endIndex
            return GroupOfPictures(
                width: samples[start].width,
                height: samples[start].height,
                parameterSets: samples[start].parameterSets,
                samples: (start..<end).map {
                    GroupOfPictures.Sample(
                        frameID: Int64($0),
                        capturedAt: samples[$0].capturedAt,
                        isKeyframe: samples[$0].isKeyframe,
                        data: samples[$0].data
                    )
                },
                target: index - start
            )
        }
    }
}
