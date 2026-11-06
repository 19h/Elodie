import CoreGraphics
import Foundation

/// Chooses which windows go in each picture, and says whether a picture is still safe to keep.
///
/// A picture holds only the windows it was asked for, so this is decided fresh just before each
/// one. A window that opens after that isn't in the list, so it can't be in the picture, however
/// briefly it was open. When in doubt, a frame is dropped: `check` looks again once the picture
/// exists, in case a window it shows has since turned out to be one that must be hidden.
public final class WindowChooser: @unchecked Sendable {
    private let inventory: WindowInventory
    private let readWindows: () -> [WindowInfo]
    private let identify: (pid_t) -> AppIdentity
    private let ownPID: pid_t?
    private let lock = NSLock()

    private var policy: ExclusionPolicy
    private var dropped = 0

    /// - Parameters:
    ///   - hideOwnWindows: whether this app's own windows are always hidden.
    ///   - identify: replaces how windows' owners are identified, for tests.
    ///   - readWindows: replaces how windows are read, for tests.
    public init(
        policy: ExclusionPolicy,
        inventory: WindowInventory = WindowInventory(),
        hideOwnWindows: Bool = true,
        identify: ((pid_t) -> AppIdentity)? = nil,
        readWindows: (() -> [WindowInfo])? = nil
    ) {
        self.policy = policy
        self.inventory = inventory
        self.identify = identify ?? { inventory.identify($0) }
        self.readWindows = readWindows ?? { inventory.onScreenWindowsAndDesktop() }
        ownPID = hideOwnWindows ? ProcessInfo.processInfo.processIdentifier : nil
    }

    public var framesDropped: Int {
        lock.withLock { dropped }
    }

    /// Takes effect from the next picture.
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

    /// The windows to put in the next picture, front to back.
    ///
    /// - Parameter owner: limits it to one process's windows, so a test sees nothing else.
    public func windowsToCapture(ownedBy owner: pid_t? = nil) -> [CGWindowID] {
        let windows = readWindows()
        // macOS can reuse a process ID, and an excluded app mustn't be mistaken for another.
        inventory.forgetProcesses(except: Set(windows.map(\.ownerPID)))
        let required = requiredExclusions(in: windows)
        return windows
            .filter { !required.contains($0.id) && (owner == nil || $0.ownerPID == owner) }
            .map(\.id)
    }

    public struct Check {
        public var windows: [WindowInfo]
        public var required: Set<CGWindowID>
        /// Whether nothing in the picture has to be hidden.
        public var isSafe: Bool
    }

    /// Checks a picture just before it would be kept. A window's title can change after it was
    /// chosen, and that can reveal it to be private.
    public func check(captured: Set<CGWindowID>) -> Check {
        let windows = readWindows()
        let required = requiredExclusions(in: windows)
        let isSafe = required.isDisjoint(with: captured)
        if !isSafe {
            lock.withLock { dropped += 1 }
        }
        return Check(windows: windows, required: required, isSafe: isSafe)
    }
}
