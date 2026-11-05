import CoreAPI
import Foundation

/// `RemindCore` for previews and tests. It keeps samples in memory.
public final class FakeCore: RemindCore, @unchecked Sendable {
    private let lock = NSLock()
    private var samples: [EncodedSample] = []
    private var finishedOCR: Set<Int64> = []
    private var recognized: [Int64: [RecognizedLine]] = [:]

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

    public func readKeyframe(of frameID: Int64) throws -> GroupOfPictures {
        var group = try readGroup(containing: frameID)
        group.samples = Array(group.samples.prefix(1))
        group.target = 0
        return group
    }

    public func neighbour(of frameID: Int64, forward: Bool) throws -> FrameRef? {
        lock.withLock {
            let index = Int(frameID) + (forward ? 1 : -1)
            guard samples.indices.contains(index) else { return nil }
            return FrameRef(id: Int64(index), capturedAt: samples[index].capturedAt)
        }
    }

    public func timeline(display: UUID, from: Date, to: Date, minimumDuration: TimeInterval) throws -> TimelineData {
        lock.withLock {
            var apps: [String?] = []
            var runs: [TimelineRun] = []
            for sample in samples where sample.displayID == display && sample.capturedAt >= from && sample.capturedAt <= to {
                let app = apps.firstIndex(of: sample.context.bundleID) ?? {
                    apps.append(sample.context.bundleID)
                    return apps.count - 1
                }()
                if let last = runs.last, last.app == app {
                    runs[runs.count - 1].end = sample.capturedAt
                } else {
                    runs.append(TimelineRun(start: sample.capturedAt, end: sample.capturedAt, app: app))
                }
            }
            return TimelineData(apps: apps, runs: runs)
        }
    }

    public func frameContext(of frameID: Int64) throws -> FrameContext? {
        lock.withLock {
            samples.indices.contains(Int(frameID)) ? samples[Int(frameID)].context : nil
        }
    }

    public func recordedApps() throws -> [String] {
        lock.withLock {
            var seen = Set<String>()
            return samples.reversed().compactMap(\.context.bundleID).filter { seen.insert($0).inserted }
        }
    }

    public func recap(from: Date, to: Date, bucket: TimeInterval) throws -> Recap {
        Recap(totalActive: 0, apps: [], activity: [], blocks: [])
    }

    public func frameText(of frameID: Int64) throws -> [String] {
        lock.withLock { recognized[frameID]?.map(\.text) ?? [] }
    }

    public func setStarred(_ starred: Bool, frameID: Int64) throws {}

    @discardableResult
    public func deleteRange(from: Date, to: Date) throws -> UInt64 { 0 }

    public func activePeriods(_ periods: [DateInterval]) throws -> [Bool] {
        lock.withLock {
            periods.map { period in samples.contains { period.contains($0.capturedAt) } }
        }
    }

    public func nextOCRBatch(max: Int, now: Date, includeDeferred: Bool) throws -> [OCRJob] {
        lock.withLock {
            let waiting = samples.indices.filter { !finishedOCR.contains(Int64($0)) }.prefix(max)
            return waiting.map {
                OCRJob(frameID: Int64($0), capturedAt: samples[$0].capturedAt, attempt: 1)
            }
        }
    }

    public func submitOCR(_ results: [OCRResult]) throws {
        lock.withLock {
            for result in results {
                finishedOCR.insert(result.frameID)
                recognized[result.frameID] = result.lines
            }
        }
    }

    public func failOCR(frameID: Int64) throws {
        lock.withLock { _ = finishedOCR.insert(frameID) }
    }

    /// A simple substring search, because previews and tests don't need ranking.
    public func search(_ text: String, facets: SearchFacets, order: SearchOrder) throws -> (any SearchSession)? {
        let needle = text.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return nil }
        let hits = lock.withLock { () -> [SearchHit] in
            recognized.keys.sorted(by: >).compactMap { frameID in
                let lines = recognized[frameID] ?? []
                guard let line = lines.first(where: { $0.text.lowercased().contains(needle) }) else {
                    return nil
                }
                let sample = samples[Int(frameID)]
                return SearchHit(
                    frameID: frameID,
                    runID: frameID,
                    capturedAt: sample.capturedAt,
                    bundleID: sample.context.bundleID,
                    window: sample.context.window,
                    url: sample.context.url,
                    rects: [line.rect],
                    snippet: line.text
                )
            }
        }
        return FakeSearchSession(page: SearchPage(hits: hits, hasMore: false))
    }
}

private struct FakeSearchSession: SearchSession {
    let page: SearchPage
    func nextPage() throws -> SearchPage { page }
    func cancel() {}
}
