import CoreABI
import CoreAPI
import CoreGraphics
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
            frontRect: sample.context.frontRect.map(NormalizedRect.init),
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
        Self.convert(try core.readGop(frameId: frameID))
    }

    public func readKeyframe(of frameID: Int64) throws -> GroupOfPictures {
        Self.convert(try core.readKeyframe(frameId: frameID))
    }

    public func neighbour(of frameID: Int64, forward: Bool) throws -> CoreAPI.FrameRef? {
        try core.neighbour(frameId: frameID, forward: forward).map {
            CoreAPI.FrameRef(id: $0.id, capturedAt: Date(milliseconds: $0.tMs))
        }
    }

    public func timeline(display: UUID, from: Date, to: Date, minimumDuration: TimeInterval) throws -> CoreAPI.TimelineData {
        let data = try core.timeline(
            displayUuid: display.data,
            fromMs: from.milliseconds,
            toMs: to.milliseconds,
            minDurationMs: Int64(minimumDuration * 1000)
        )
        return CoreAPI.TimelineData(
            apps: data.apps,
            runs: data.runs.map {
                CoreAPI.TimelineRun(
                    start: Date(milliseconds: $0.startMs),
                    end: Date(milliseconds: $0.endMs),
                    app: Int($0.app)
                )
            }
        )
    }

    public func frameContext(of frameID: Int64) throws -> CoreAPI.FrameContext? {
        try core.frameContext(frameId: frameID).map {
            CoreAPI.FrameContext(bundleID: $0.bundleId, window: $0.window, url: $0.url)
        }
    }

    public func recordedApps() throws -> [String] {
        try core.recordedApps()
    }

    public func recap(from: Date, to: Date, bucket: TimeInterval) throws -> CoreAPI.Recap {
        let recap = try core.recap(
            fromMs: from.milliseconds,
            toMs: to.milliseconds,
            bucketMs: Int64(bucket * 1000)
        )
        return CoreAPI.Recap(
            totalActive: Double(recap.totalActiveMs) / 1000,
            apps: recap.apps.map {
                CoreAPI.AppTime(bundleID: $0.bundleId, duration: Double($0.milliseconds) / 1000)
            },
            activity: recap.activity.map { Double($0) / 1000 },
            blocks: recap.blocks.map {
                CoreAPI.ActivityBlock(
                    start: Date(milliseconds: $0.startMs),
                    end: Date(milliseconds: $0.endMs),
                    bundleID: $0.bundleId,
                    window: $0.window,
                    url: $0.url
                )
            }
        )
    }

    public func frameText(of frameID: Int64) throws -> [String] {
        try core.frameText(frameId: frameID)
    }

    public func frameLines(of frameID: Int64) throws -> [CoreAPI.RecognizedLine] {
        try core.frameLines(frameId: frameID).map { line in
            CoreAPI.RecognizedLine(
                text: line.text,
                rect: CGRect(
                    x: CGFloat(line.rect.x),
                    y: CGFloat(line.rect.y),
                    width: CGFloat(line.rect.width),
                    height: CGFloat(line.rect.height)
                )
            )
        }
    }

    public func recordMeeting(title: String?, from: Date, to: Date) throws {
        try core.recordMeeting(title: title, tStartMs: from.milliseconds, tEndMs: to.milliseconds)
    }

    public func meetings(from: Date, to: Date) throws -> [CoreAPI.RecordedMeeting] {
        try core.meetings(fromMs: from.milliseconds, toMs: to.milliseconds).map { meeting in
            CoreAPI.RecordedMeeting(
                title: meeting.title,
                start: Date(timeIntervalSince1970: Double(meeting.tStartMs) / 1000),
                end: meeting.tEndMs.map { Date(timeIntervalSince1970: Double($0) / 1000) }
            )
        }
    }

    public func appendTranscript(_ words: [CoreAPI.SpokenWord], title: String?) throws {
        try core.appendTranscript(
            words: words.map {
                SpokenWordInput(
                    text: $0.text,
                    tMs: $0.time.milliseconds,
                    durationMs: Int64($0.duration * 1000),
                    confidence: $0.confidence,
                    isMe: $0.isMe
                )
            },
            title: title
        )
    }

    public func transcript(from: Date, to: Date) throws -> [CoreAPI.TranscriptLine] {
        try core.transcript(fromMs: from.milliseconds, toMs: to.milliseconds).map {
            CoreAPI.TranscriptLine(
                text: $0.text,
                time: Date(milliseconds: $0.tMs),
                duration: Double($0.durationMs) / 1000,
                isMe: $0.isMe
            )
        }
    }

    public func setStarred(_ starred: Bool, frameID: Int64) throws {
        try core.setStarred(frameId: frameID, starred: starred)
    }

    @discardableResult
    public func deleteRange(from: Date, to: Date) throws -> UInt64 {
        try core.deleteRange(fromMs: from.milliseconds, toMs: to.milliseconds)
    }

    public func activePeriods(_ periods: [DateInterval]) throws -> [Bool] {
        try core.activePeriods(periods: periods.map {
            Period(fromMs: $0.start.milliseconds, toMs: $0.end.milliseconds)
        })
    }

    private static func convert(_ gop: Gop) -> GroupOfPictures {
        GroupOfPictures(
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

extension LiveCore {
    public func nextOCRBatch(max: Int, now: Date, includeDeferred: Bool) throws -> [CoreAPI.OCRJob] {
        try core.nextOcrBatch(max: UInt32(max), nowMs: now.milliseconds, includeDeferred: includeDeferred).map {
            CoreAPI.OCRJob(frameID: $0.frameId, capturedAt: Date(milliseconds: $0.tMs), attempt: Int($0.attempt))
        }
    }

    public func submitOCR(_ results: [CoreAPI.OCRResult]) throws {
        try core.submitOcr(results: results.map { result in
            OcrResultInput(
                frameId: result.frameID,
                lines: result.lines.map { OcrLineInput(text: $0.text, rect: NormalizedRect($0.rect)) }
            )
        })
    }

    public func failOCR(frameID: Int64) throws {
        try core.failOcr(frameId: frameID)
    }

    public func search(
        _ text: String,
        facets: CoreAPI.SearchFacets,
        order: CoreAPI.SearchOrder
    ) throws -> (any CoreAPI.SearchSession)? {
        let handle = try core.search(
            text: text,
            facets: CoreABI.SearchFacets(
                bundleIds: facets.bundleIDs,
                fromMs: facets.from?.milliseconds,
                toMs: facets.to?.milliseconds,
                starredOnly: facets.starredOnly,
                transcriptsOnly: facets.transcriptsOnly
            ),
            order: order == .relevance ? .relevance : .newest
        )
        return handle.map(LiveSearchSession.init)
    }
}

private struct LiveSearchSession: CoreAPI.SearchSession {
    let handle: SearchHandle

    func nextPage() throws -> CoreAPI.SearchPage {
        let page = try handle.nextPage()
        return CoreAPI.SearchPage(
            hits: page.hits.map { hit in
                CoreAPI.SearchHit(
                    frameID: hit.frameId,
                    runID: hit.runId,
                    capturedAt: Date(milliseconds: hit.tMs),
                    bundleID: hit.bundleId,
                    window: hit.window,
                    url: hit.url,
                    rects: hit.rects.map(CGRect.init),
                    snippet: hit.snippet,
                    isTranscript: hit.isTranscript
                )
            },
            hasMore: page.hasMore
        )
    }

    func cancel() {
        handle.cancel()
    }
}

extension NormalizedRect {
    init(_ rect: CGRect) {
        self.init(x: Float(rect.minX), y: Float(rect.minY), width: Float(rect.width), height: Float(rect.height))
    }
}

extension CGRect {
    init(_ rect: NormalizedRect) {
        self.init(x: CGFloat(rect.x), y: CGFloat(rect.y), width: CGFloat(rect.width), height: CGFloat(rect.height))
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
