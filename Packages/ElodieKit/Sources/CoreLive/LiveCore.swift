import CoreABI
import CoreAPI
import CoreGraphics
import Foundation

/// `ElodieCore` backed by the Rust library.
public final class LiveCore: ElodieCore {
    private let core: Core

    /// Opens a vault, recovering from any crash. Don't call this on the main thread.
    public init(vaultDirectory: URL, masterKey: Data) throws {
        core = try Core.open(root: vaultDirectory.path, masterKey: masterKey)
    }

    /// How many pieces of the recording couldn't be read when the vault was opened.
    public var unreadableChunks: UInt64 {
        core.recovery().chunksUnreadable
    }

    /// Whether opening failed because another process has the vault.
    public static func isVaultBusy(_ error: any Error) -> Bool {
        if case CoreError.VaultBusy = error { return true }
        return false
    }

    /// Whether opening failed because this isn't the key for the vault.
    public static func isWrongKey(_ error: any Error) -> Bool {
        if case CoreError.Storage(let message) = error {
            return message.contains("not a database")
        }
        return false
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

    public func recordedPeriods(display: UUID, minimumGap: TimeInterval) throws -> [DateInterval] {
        try core.recordedPeriods(displayUuid: display.data, minGapMs: Int64(minimumGap * 1000)).map {
            DateInterval(start: Date(milliseconds: $0.fromMs), end: Date(milliseconds: max($0.fromMs, $0.toMs)))
        }
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

    public func displays() throws -> [CoreAPI.RecordedDisplay] {
        try core.displays().compactMap { display in
            guard let id = UUID(bytes: display.uuid) else { return nil }
            return CoreAPI.RecordedDisplay(
                id: id,
                width: Int(display.width),
                height: Int(display.height),
                first: Date(milliseconds: display.firstMs),
                last: Date(milliseconds: display.lastMs)
            )
        }
    }

    public func isStarred(frameID: Int64) throws -> Bool {
        try core.isStarred(frameId: frameID)
    }

    public func stars(display: UUID, from: Date, to: Date) throws -> [CoreAPI.StarredFrame] {
        try core.stars(display: display.data, fromMs: from.milliseconds, toMs: to.milliseconds).map {
            CoreAPI.StarredFrame(id: $0.frameId, time: Date(milliseconds: $0.tMs))
        }
    }

    public func segment(display: UUID, at time: Date) throws -> CoreAPI.SegmentDetails? {
        try core.segmentAt(display: display.data, tMs: time.milliseconds).map {
            CoreAPI.SegmentDetails(
                bundleID: $0.bundleId,
                window: $0.window,
                url: $0.url,
                start: Date(milliseconds: $0.tStartMs),
                end: Date(milliseconds: $0.tEndMs)
            )
        }
    }

    public func sliceSummary(from: Date, to: Date) throws -> CoreAPI.SliceSummary {
        let summary = try core.sliceSummary(fromMs: from.milliseconds, toMs: to.milliseconds)
        return CoreAPI.SliceSummary(
            frames: Int(summary.frames),
            bytes: summary.bytes,
            starred: Int(summary.starred),
            transcriptLines: Int(summary.transcriptLines),
            apps: summary.apps.map { (bundleID: $0.bundleId, duration: Double($0.durationMs) / 1000) },
            windows: summary.windows,
            dependentFrames: Int(summary.dependentFrames),
            dependentUntil: summary.dependentUntilMs.map(Date.init(milliseconds:))
        )
    }

    public func transcriptSessions(from: Date, to: Date, limit: Int) throws -> [CoreAPI.TranscriptSession] {
        try core.transcriptSessions(fromMs: from.milliseconds, toMs: to.milliseconds, limit: UInt32(limit)).map {
            CoreAPI.TranscriptSession(
                title: $0.title,
                start: Date(milliseconds: $0.tStartMs),
                end: Date(milliseconds: $0.tEndMs),
                lines: Int($0.lines)
            )
        }
    }

    public func storageByApp() throws -> [CoreAPI.AppUsage] {
        try core.storageByApp().map {
            CoreAPI.AppUsage(bundleID: $0.bundleId, bytes: $0.bytes, frames: Int($0.frames))
        }
    }

    public func appStretches(bundleID: String) throws -> [DateInterval] {
        try core.appStretches(bundleId: bundleID).map {
            DateInterval(
                start: Date(milliseconds: $0.tStartMs),
                end: Date(milliseconds: max($0.tStartMs, $0.tEndMs))
            )
        }
    }

    public func moments(facets: CoreAPI.SearchFacets, before: Date?, limit: Int) throws -> [CoreAPI.SearchHit] {
        try core.moments(query: CoreABI.MomentQuery(
            bundleIds: facets.bundleIDs,
            starredOnly: facets.starredOnly,
            transcriptsOnly: facets.transcriptsOnly,
            beforeMs: before?.milliseconds,
            limit: UInt32(limit)
        )).map(CoreAPI.SearchHit.init(live:))
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
                CoreAPI.SearchHit(live: hit)
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

private extension CoreAPI.SearchHit {
    init(live hit: CoreABI.SearchHit) {
        self.init(
            frameID: hit.frameId,
            runID: hit.runId,
            capturedAt: Date(milliseconds: hit.tMs),
            bundleID: hit.bundleId,
            window: hit.window,
            url: hit.url,
            rects: hit.rects.map(CGRect.init),
            snippet: hit.snippet,
            isTranscript: hit.isTranscript,
            display: hit.displayUuid.flatMap(UUID.init(bytes:))
        )
    }
}

private extension UUID {
    init?(bytes: Data) {
        guard bytes.count == 16 else { return nil }
        let array = [UInt8](bytes)
        self.init(uuid: (
            array[0], array[1], array[2], array[3], array[4], array[5], array[6], array[7],
            array[8], array[9], array[10], array[11], array[12], array[13], array[14], array[15]
        ))
    }
}
