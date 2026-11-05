import CoreGraphics
import Foundation

/// A window currently on screen.
public struct WindowInfo: Sendable, Equatable {
    public var id: CGWindowID
    public var ownerPID: pid_t
    public var title: String?
    public var layer: Int
    public var bounds: CGRect

    public init(id: CGWindowID, ownerPID: pid_t, title: String?, layer: Int, bounds: CGRect) {
        self.id = id
        self.ownerPID = ownerPID
        self.title = title
        self.layer = layer
        self.bounds = bounds
    }
}

/// Which apps' windows are left out of recording.
public struct ExclusionPolicy: Sendable, Equatable {
    public var excludedBundleIDs: Set<String>
    public var excludesPrivateWindows: Bool

    public init(excludedBundleIDs: Set<String>, excludesPrivateWindows: Bool = true) {
        self.excludedBundleIDs = excludedBundleIDs
        self.excludesPrivateWindows = excludesPrivateWindows
    }
}

/// What's known about the app that owns a window.
public struct AppIdentity: Sendable, Equatable {
    public var bundleID: String?
    public var family: BrowserFamily?

    public init(bundleID: String?, family: BrowserFamily?) {
        self.bundleID = bundleID
        self.family = family
    }
}

extension ExclusionPolicy {
    /// The windows that must not appear in a recorded frame.
    public func requiredExclusions(
        in windows: [WindowInfo],
        identify: (pid_t) -> AppIdentity
    ) -> Set<CGWindowID> {
        var required = Set<CGWindowID>()
        for window in windows {
            let app = identify(window.ownerPID)
            if let bundleID = app.bundleID, excludedBundleIDs.contains(bundleID) {
                required.insert(window.id)
            } else if excludesPrivateWindows, let family = app.family,
                      PrivateWindowRules.isPrivate(title: window.title, family: family) {
                required.insert(window.id)
            }
        }
        return required
    }
}

/// Decides whether a captured frame is safe to keep.
///
/// A frame is safe only if every window that must be hidden was already in the
/// filter when the frame was composed. This errs toward dropping: while a new
/// private window is on its way into the filter, frames are thrown away rather
/// than recorded. Opening an ordinary window changes nothing here, so it costs no
/// frames.
public struct ExclusionGate: Sendable, Equatable {
    /// The windows hidden by the filter in effect.
    public private(set) var committed: Set<CGWindowID> = []
    /// When that filter took effect, in mach time. No frame is safe before the
    /// first one has.
    public private(set) var committedAt: UInt64?

    public init() {}

    /// Records that a filter hiding `windows` has taken effect.
    public mutating func commit(_ windows: Set<CGWindowID>, at machTime: UInt64) {
        committed = windows
        committedAt = machTime
    }

    public enum Verdict: Sendable, Equatable {
        case allow
        /// The filter doesn't cover these windows yet. Update it.
        case dropNeedsFilter(Set<CGWindowID>)
        /// The frame was composed before the filter took effect.
        case dropFrameTooOld
        /// No filter has taken effect yet.
        case dropNoFilter
    }

    public func check(required: Set<CGWindowID>, frameDisplayTime: UInt64) -> Verdict {
        guard let committedAt else { return .dropNoFilter }
        if !required.isSubset(of: committed) {
            return .dropNeedsFilter(required)
        }
        return frameDisplayTime > committedAt ? .allow : .dropFrameTooOld
    }
}
