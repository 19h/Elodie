import CoreGraphics
import Foundation

/// What the running core was built with.
public struct CoreInfo: Sendable, Equatable {
    public var version: String
    public var sqliteVersion: String
    public var cipherProvider: String

    public init(version: String, sqliteVersion: String, cipherProvider: String) {
        self.version = version
        self.sqliteVersion = sqliteVersion
        self.cipherProvider = cipherProvider
    }
}

/// What was on screen when a frame was captured.
public struct FrameContext: Sendable, Equatable {
    public var bundleID: String?
    public var window: String?
    public var url: String?
    public var profile: String?
    /// The front window as a fraction of the display, with the origin at the top left.
    public var frontRect: CGRect?

    public init(
        bundleID: String? = nil,
        window: String? = nil,
        url: String? = nil,
        profile: String? = nil,
        frontRect: CGRect? = nil
    ) {
        self.bundleID = bundleID
        self.window = window
        self.url = url
        self.profile = profile
        self.frontRect = frontRect
    }
}

/// An encoded video sample on its way to the log.
public struct EncodedSample: Sendable {
    public var displayID: UUID
    public var width: Int
    public var height: Int
    /// The codec's parameter sets (`hvcC`). A change starts a new chunk.
    public var parameterSets: Data
    public var capturedAt: Date
    /// A monotonic timestamp, used to order frames if the wall clock jumps.
    public var monotonicNanoseconds: UInt64
    public var isKeyframe: Bool
    public var context: FrameContext
    public var data: Data

    public init(
        displayID: UUID,
        width: Int,
        height: Int,
        parameterSets: Data,
        capturedAt: Date,
        monotonicNanoseconds: UInt64,
        isKeyframe: Bool,
        context: FrameContext,
        data: Data
    ) {
        self.displayID = displayID
        self.width = width
        self.height = height
        self.parameterSets = parameterSets
        self.capturedAt = capturedAt
        self.monotonicNanoseconds = monotonicNanoseconds
        self.isKeyframe = isKeyframe
        self.context = context
        self.data = data
    }
}

/// What happened to an appended sample.
public enum AppendOutcome: Sendable, Equatable {
    case accepted
    /// Dropped because the queue is full. Force a keyframe next.
    case droppedQueueFull
    /// Dropped because a keyframe is required next. Force one.
    case needsKeyframe
}

/// A recorded frame's identity and when it was captured.
public struct FrameRef: Sendable, Equatable, Hashable {
    public var id: Int64
    public var capturedAt: Date

    public init(id: Int64, capturedAt: Date) {
        self.id = id
        self.capturedAt = capturedAt
    }
}

/// A keyframe and the samples that depend on it, enough to decode any of them.
public struct GroupOfPictures: Sendable {
    public struct Sample: Sendable {
        public var frameID: Int64
        public var capturedAt: Date
        public var isKeyframe: Bool
        public var data: Data

        public init(frameID: Int64, capturedAt: Date, isKeyframe: Bool, data: Data) {
            self.frameID = frameID
            self.capturedAt = capturedAt
            self.isKeyframe = isKeyframe
            self.data = data
        }
    }

    public var width: Int
    public var height: Int
    public var parameterSets: Data
    public var samples: [Sample]
    /// The index in `samples` of the frame that was asked for.
    public var target: Int

    public init(width: Int, height: Int, parameterSets: Data, samples: [Sample], target: Int) {
        self.width = width
        self.height = height
        self.parameterSets = parameterSets
        self.samples = samples
        self.target = target
    }
}

/// Counters for monitoring.
public struct CoreStats: Sendable, Equatable {
    public var loggedFrames: UInt64
    public var indexedFrames: UInt64
    public var droppedFrames: UInt64
    public var appendFailures: UInt64
    public var isDiskFull: Bool

    public init(loggedFrames: UInt64, indexedFrames: UInt64, droppedFrames: UInt64, appendFailures: UInt64, isDiskFull: Bool) {
        self.loggedFrames = loggedFrames
        self.indexedFrames = indexedFrames
        self.droppedFrames = droppedFrames
        self.appendFailures = appendFailures
        self.isDiskFull = isDiskFull
    }
}

/// A stretch of time in one app.
public struct TimelineRun: Sendable, Equatable {
    public var start: Date
    public var end: Date
    /// An index into `TimelineData.apps`.
    public var app: Int

    public init(start: Date, end: Date, app: Int) {
        self.start = start
        self.end = end
        self.app = app
    }
}

/// Runs for part of the timeline.
public struct TimelineData: Sendable, Equatable {
    /// Each app's bundle ID.
    public var apps: [String?]
    public var runs: [TimelineRun]

    public init(apps: [String?], runs: [TimelineRun]) {
        self.apps = apps
        self.runs = runs
    }
}

/// Time spent in one app.
public struct AppTime: Sendable, Equatable, Identifiable {
    public var bundleID: String?
    public var duration: TimeInterval
    public var id: String { bundleID ?? "" }

    public init(bundleID: String?, duration: TimeInterval) {
        self.bundleID = bundleID
        self.duration = duration
    }
}

/// A long stretch of focus.
public struct ActivityBlock: Sendable, Equatable, Identifiable {
    public var start: Date
    public var end: Date
    public var bundleID: String?
    public var window: String?
    public var url: String?
    public var id: Date { start }

    public init(start: Date, end: Date, bundleID: String?, window: String?, url: String?) {
        self.start = start
        self.end = end
        self.bundleID = bundleID
        self.window = window
        self.url = url
    }
}

/// A summary of what was recorded in a period.
public struct Recap: Sendable, Equatable {
    public var totalActive: TimeInterval
    public var apps: [AppTime]
    /// Active seconds in each bucket of the period.
    public var activity: [TimeInterval]
    public var blocks: [ActivityBlock]

    public init(totalActive: TimeInterval, apps: [AppTime], activity: [TimeInterval], blocks: [ActivityBlock]) {
        self.totalActive = totalActive
        self.apps = apps
        self.activity = activity
        self.blocks = blocks
    }
}

/// A frame waiting for OCR.
public struct OCRJob: Sendable, Equatable {
    public var frameID: Int64
    public var capturedAt: Date
    public var attempt: Int

    public init(frameID: Int64, capturedAt: Date, attempt: Int) {
        self.frameID = frameID
        self.capturedAt = capturedAt
        self.attempt = attempt
    }
}

/// A piece of text found in a frame.
public struct RecognizedLine: Sendable, Equatable {
    public var text: String
    /// As a fraction of the frame, with the origin at the top left.
    public var rect: CGRect

    public init(text: String, rect: CGRect) {
        self.text = text
        self.rect = rect
    }
}

/// What OCR found in a frame.
public struct OCRResult: Sendable, Equatable {
    public var frameID: Int64
    public var lines: [RecognizedLine]

    public init(frameID: Int64, lines: [RecognizedLine]) {
        self.frameID = frameID
        self.lines = lines
    }
}

public enum SearchOrder: Sendable, Equatable {
    case relevance
    case newest
}

/// Limits on what's searched.
public struct SearchFacets: Sendable, Equatable {
    public var bundleIDs: [String]
    public var from: Date?
    public var to: Date?
    public var starredOnly: Bool
    /// Only what was said, rather than what was on screen.
    public var transcriptsOnly: Bool

    public init(
        bundleIDs: [String] = [],
        from: Date? = nil,
        to: Date? = nil,
        starredOnly: Bool = false,
        transcriptsOnly: Bool = false
    ) {
        self.bundleIDs = bundleIDs
        self.from = from
        self.to = to
        self.starredOnly = starredOnly
        self.transcriptsOnly = transcriptsOnly
    }
}

/// A transcribed word.
public struct SpokenWord: Sendable, Equatable {
    public var text: String
    public var time: Date
    public var duration: TimeInterval
    public var confidence: Float
    /// Whether this came from the microphone rather than the computer's audio.
    public var isMe: Bool

    public init(text: String, time: Date, duration: TimeInterval, confidence: Float, isMe: Bool) {
        self.text = text
        self.time = time
        self.duration = duration
        self.confidence = confidence
        self.isMe = isMe
    }
}

/// A line of a transcript.
/// A meeting that was transcribed.
public struct RecordedMeeting: Sendable, Equatable, Identifiable {
    public var title: String?
    public var start: Date
    public var end: Date?
    public var id: Date { start }

    public init(title: String?, start: Date, end: Date?) {
        self.title = title
        self.start = start
        self.end = end
    }
}

public struct TranscriptLine: Sendable, Equatable, Identifiable {
    public var text: String
    public var time: Date
    public var duration: TimeInterval
    public var isMe: Bool
    public var id: Date { time }

    public init(text: String, time: Date, duration: TimeInterval, isMe: Bool) {
        self.text = text
        self.time = time
        self.duration = duration
        self.isMe = isMe
    }
}

/// A moment that matched a search.
public struct SearchHit: Sendable, Equatable, Identifiable {
    public var frameID: Int64
    public var runID: Int64
    public var capturedAt: Date
    public var bundleID: String?
    public var window: String?
    public var url: String?
    /// Where the matches are, as fractions of the frame.
    public var rects: [CGRect]
    public var snippet: String
    /// Whether this was said rather than shown. Such a hit has no frame of its own.
    public var isTranscript: Bool

    public var id: String { isTranscript ? "said-\(runID)-\(capturedAt.timeIntervalSince1970)" : "frame-\(frameID)" }

    public init(
        frameID: Int64,
        runID: Int64,
        capturedAt: Date,
        bundleID: String?,
        window: String?,
        url: String?,
        rects: [CGRect],
        snippet: String,
        isTranscript: Bool = false
    ) {
        self.frameID = frameID
        self.runID = runID
        self.capturedAt = capturedAt
        self.bundleID = bundleID
        self.window = window
        self.url = url
        self.rects = rects
        self.snippet = snippet
        self.isTranscript = isTranscript
    }
}

public struct SearchPage: Sendable, Equatable {
    public var hits: [SearchHit]
    public var hasMore: Bool

    public init(hits: [SearchHit], hasMore: Bool) {
        self.hits = hits
        self.hasMore = hasMore
    }
}

/// A search in progress.
public protocol SearchSession: Sendable {
    /// Fetches the next page. This blocks, so don't call it on the main thread.
    func nextPage() throws -> SearchPage
    /// Stops a query that's running, from any thread.
    func cancel()
}

/// The app's view of the Rust core.
///
/// Feature code depends on this protocol and never on the generated bindings,
/// so previews and tests can run against `FakeCore` with no vault or screen.
public protocol RemindCore: Sendable {
    func info() throws -> CoreInfo
    func stats() -> CoreStats
    func append(_ sample: EncodedSample) throws -> AppendOutcome
    func sealAll() throws
    func lookup(display: UUID, at time: Date) throws -> FrameRef?
    func readGroup(containing frameID: Int64) throws -> GroupOfPictures
    /// Reads only the keyframe of a frame's group, for scrubbing too fast to decode
    /// everything. The result has one sample, whose frame may be earlier than asked.
    func readKeyframe(of frameID: Int64) throws -> GroupOfPictures
    /// The next frame on the same display, going forward or back.
    func neighbour(of frameID: Int64, forward: Bool) throws -> FrameRef?
    /// Runs for a period, with anything shorter than `minimumDuration` merged. Pass
    /// the time one pixel covers at the current zoom.
    func timeline(display: UUID, from: Date, to: Date, minimumDuration: TimeInterval) throws -> TimelineData
    /// Which of the given periods have any recording.
    func activePeriods(_ periods: [DateInterval]) throws -> [Bool]
    /// What was on screen for a frame.
    func frameContext(of frameID: Int64) throws -> FrameContext?
    /// Every app that has been recorded, most recent first.
    func recordedApps() throws -> [String]
    /// Summarises what was recorded in a period.
    func recap(from: Date, to: Date, bucket: TimeInterval) throws -> Recap
    /// The text a frame shows, front window first.
    func frameText(of frameID: Int64) throws -> [String]
    /// The lines of text a frame shows and where they are, front window first.
    func frameLines(of frameID: Int64) throws -> [RecognizedLine]
    /// Notes a meeting that was transcribed.
    func recordMeeting(title: String?, from: Date, to: Date) throws
    /// Meetings that started in a period, earliest first.
    func meetings(from: Date, to: Date) throws -> [RecordedMeeting]
    /// Stores transcribed words, dropping any that were only the speakers' echo.
    func appendTranscript(_ words: [SpokenWord], title: String?) throws
    /// What was said in a period.
    func transcript(from: Date, to: Date) throws -> [TranscriptLine]
    func setStarred(_ starred: Bool, frameID: Int64) throws
    /// Permanently deletes frames in a period, and their text. Returns how many were
    /// removed, which can include a few after the period that depended on them. This
    /// blocks, so don't call it on the main thread.
    @discardableResult
    func deleteRange(from: Date, to: Date) throws -> UInt64
    func nextOCRBatch(max: Int, now: Date, includeDeferred: Bool) throws -> [OCRJob]
    func submitOCR(_ results: [OCRResult]) throws
    func failOCR(frameID: Int64) throws
    /// Starts a search. Returns `nil` if the text has nothing searchable in it.
    func search(_ text: String, facets: SearchFacets, order: SearchOrder) throws -> (any SearchSession)?
}
