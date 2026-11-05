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

    public var framesDropped: Int {
        lock.withLock { dropped }
    }

    public func update(policy: ExclusionPolicy) {
        lock.withLock { self.policy = policy }
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
        let appliedAt = try await stream.start(excluding: required, interval: interval)
        lock.withLock {
            self.stream = stream
            gate.commit(required, at: appliedAt)
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
            guard !updateInFlight else { return nil }
            updateInFlight = true
            return self.stream
        }
        guard let stream else { return }
        Task { [weak self] in
            do {
                let appliedAt = try await stream.update(excluding: required)
                self?.lock.withLock {
                    self?.gate.commit(required, at: appliedAt)
                    self?.updateInFlight = false
                }
            } catch {
                self?.lock.withLock { self?.updateInFlight = false }
            }
        }
    }
}
