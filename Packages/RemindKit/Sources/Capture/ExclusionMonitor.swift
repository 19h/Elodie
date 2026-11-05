import CoreGraphics
import Foundation

/// Keeps a stream's filter covering the windows that must be hidden, and says
/// whether a frame is safe to keep. See `ExclusionGate` for the rule.
public final class ExclusionMonitor: @unchecked Sendable {
    private let inventory: WindowInventory
    private let identify: (pid_t) -> AppIdentity
    private let ownPID: pid_t?
    private let lock = NSLock()

    private var policy: ExclusionPolicy
    private var gate = ExclusionGate()
    private var updateInFlight = false
    private weak var stream: DisplayStream?
    private var dropped = 0
    private var watcher: DispatchSourceTimer?
    private var windowChecks = 0
    private var windowCheckTime: Duration = .zero

    private var lastWindowIDs: [CGWindowID] = []
    /// The policy changed, so the filter may be hiding something it no longer should.
    private var filterMayBeStale = false

    /// How often windows are looked at between frames. A window that's open for at least
    /// this long can't reach a recording, because it's noticed before it can close unseen.
    public static let watchInterval: TimeInterval = 0.2

    /// How long a new filter is given to reach the screen. Updating a filter returns a few
    /// milliseconds before frames stop showing what it hides: spike 2 caught frames composed
    /// 1 to 5 ms after it returned with the window still in them. At the usual capture rate
    /// this costs at most one frame each time a private window opens.
    public static let filterSettleTime: TimeInterval = 0.25

    /// The time a filter applied just now can be trusted from.
    private static func settled(from machTime: UInt64 = mach_absolute_time()) -> UInt64 {
        var base = mach_timebase_info()
        mach_timebase_info(&base)
        return machTime + UInt64(filterSettleTime * 1e9) * UInt64(base.denom) / UInt64(base.numer)
    }

    /// - Parameters:
    ///   - hideOwnWindows: whether this app's own windows are always hidden.
    ///   - identify: replaces how windows' owners are identified, for tests.
    public init(
        policy: ExclusionPolicy,
        inventory: WindowInventory = WindowInventory(),
        hideOwnWindows: Bool = true,
        identify: ((pid_t) -> AppIdentity)? = nil
    ) {
        self.policy = policy
        self.inventory = inventory
        self.identify = identify ?? { inventory.identify($0) }
        ownPID = hideOwnWindows ? ProcessInfo.processInfo.processIdentifier : nil
    }

    deinit {
        watcher?.cancel()
    }

    /// The gate's state, for explaining a frame that shouldn't have been allowed.
    public var gateState: ExclusionGate {
        lock.withLock { gate }
    }

    /// How much the watcher costs, for measuring.
    public var averageWindowCheck: Duration {
        lock.withLock { windowChecks == 0 ? .zero : windowCheckTime / windowChecks }
    }

    public var framesDropped: Int {
        lock.withLock { dropped }
    }

    /// Takes effect at the next look, which is within a fraction of a second. An app that's
    /// been newly excluded drops frames until then, and one that's no longer excluded comes
    /// back into the filter's view.
    public func update(policy: ExclusionPolicy) {
        lock.withLock {
            guard policy != self.policy else { return }
            self.policy = policy
            filterMayBeStale = true
            lastWindowIDs = []
        }
    }

    /// The windows that must be hidden right now.
    public func requiredExclusions(in windows: [WindowInfo]) -> Set<CGWindowID> {
        let policy = lock.withLock { self.policy }
        var required = policy.requiredExclusions(in: windows, identify: identify)
        if let ownPID {
            for window in windows where window.ownerPID == ownPID {
                required.insert(window.id)
            }
        }
        return required
    }

    /// Starts `stream` with a filter covering the windows that must be hidden.
    public func start(_ stream: DisplayStream, interval: TimeInterval = DisplayStream.captureInterval) async throws {
        let required = requiredExclusions(in: inventory.onScreenWindows())
        let applied = try await stream.start(excluding: required, interval: interval)
        lock.withLock {
            self.stream = stream
            gate.commit(applied.covered, at: Self.settled(from: applied.appliedAt))
            filterMayBeStale = false
        }
        startWatching()
    }

    /// Stops watching windows, for when capture has stopped.
    public func stop() {
        lock.withLock {
            watcher?.cancel()
            watcher = nil
            stream = nil
        }
    }

    /// Frames only arrive every couple of seconds, which leaves plenty of time for a private
    /// window to open and close unseen. This looks between frames, so the filter is usually
    /// updated before the next frame is composed, and no frame has to be lost at all.
    private func startWatching() {
        lock.withLock {
            guard watcher == nil else { return }
            let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
            timer.schedule(
                deadline: .now() + Self.watchInterval,
                repeating: Self.watchInterval,
                leeway: .milliseconds(40)
            )
            timer.setEventHandler { [weak self] in self?.watch() }
            timer.resume()
            watcher = timer
        }
    }

    /// Listing window IDs costs little, and reading every window's details costs a lot, so
    /// the details are only read when the set of windows has changed. A title changing on
    /// an existing window is picked up when the next frame is checked.
    private func watch() {
        let clock = ContinuousClock()
        let started = clock.now
        let ids = inventory.onScreenWindowIDs()
        let changed = lock.withLock { () -> Bool in
            defer { lastWindowIDs = ids }
            return ids != lastWindowIDs
        }
        var missing = Set<CGWindowID>()
        var required = Set<CGWindowID>()
        var stale = false
        if changed {
            let windows = inventory.onScreenWindows()
            inventory.forgetProcesses(except: Set(windows.map(\.ownerPID)))
            required = requiredExclusions(in: windows)
            (missing, stale) = lock.withLock {
                (gate.observe(required: required, now: mach_absolute_time()), filterMayBeStale)
            }
        }
        lock.withLock {
            windowChecks += 1
            windowCheckTime += clock.now - started
        }
        if !missing.isEmpty || stale {
            refreshFilter(required)
        }
    }

    public struct Check {
        public var windows: [WindowInfo]
        public var required: Set<CGWindowID>
        public var verdict: ExclusionGate.Verdict
    }

    /// Checks a frame just before it would be kept. This also starts updating the
    /// filter if it no longer covers everything.
    public func check(frameDisplayTime: UInt64) -> Check {
        let windows = inventory.onScreenWindows()
        let required = requiredExclusions(in: windows)
        let verdict = lock.withLock { gate.check(required: required, frameDisplayTime: frameDisplayTime) }
        switch verdict {
        case .allow:
            break
        case .dropNeedsFilter(let needed):
            lock.withLock { dropped += 1 }
            refreshFilter(needed)
        case .dropFrameTooOld, .dropNoFilter:
            lock.withLock { dropped += 1 }
        }
        return Check(windows: windows, required: required, verdict: verdict)
    }

    private func refreshFilter(_ required: Set<CGWindowID>) {
        let stream = lock.withLock { () -> DisplayStream? in
            guard !updateInFlight, let stream = self.stream else { return nil }
            updateInFlight = true
            filterMayBeStale = false
            return stream
        }
        guard let stream else { return }
        Task { [weak self] in
            do {
                let applied = try await stream.update(excluding: required)
                self?.lock.withLock {
                    self?.gate.commit(applied.covered, at: Self.settled(from: applied.appliedAt))
                    self?.updateInFlight = false
                }
            } catch {
                // Frames keep being dropped while nothing covers these windows, and the next
                // look at them tries again.
                self?.lock.withLock { self?.updateInFlight = false }
            }
        }
    }
}
