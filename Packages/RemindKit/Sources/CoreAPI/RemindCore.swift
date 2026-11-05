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

    public init(bundleID: String? = nil, window: String? = nil, url: String? = nil, profile: String? = nil) {
        self.bundleID = bundleID
        self.window = window
        self.url = url
        self.profile = profile
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
}
