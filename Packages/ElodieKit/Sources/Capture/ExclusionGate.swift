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
                      PrivateWindowRules.isPrivate(title: window.title, family: family)
                        || Self.isUntitledBrowserWindow(window) {
                required.insert(window.id)
            }
        }
        return required
    }
}

extension ExclusionPolicy {
    /// A browser window whose title isn't known yet can't be confirmed safe, so it's treated
    /// as private until it has one. A new window can exist for a moment before its title
    /// does. Small and floating windows are tooltips and popups, not pages.
    private static func isUntitledBrowserWindow(_ window: WindowInfo) -> Bool {
        (window.title ?? "").isEmpty
            && window.layer == 0
            && window.bounds.width >= 200
            && window.bounds.height >= 120
    }
}

/// Decides whether a captured frame is safe to keep.
///
/// A frame is safe only if every window that must be hidden was already in the
/// filter when the frame was composed. This errs toward dropping: while a new
/// private window is on its way into the filter, frames are thrown away rather
/// than recorded. Opening an ordinary window changes nothing here, so it costs no
/// frames.
///
/// A frame gets checked a moment after it was composed, by which time a window in it may
/// have closed. So what's on screen now isn't enough to decide. The gate also remembers
/// each window it saw that the filter didn't cover, and once that window has gone, it
/// treats everything composed up to that moment as unsafe.
public struct ExclusionGate: Sendable, Equatable {
    /// The windows hidden by the filter in effect.
    public private(set) var committed: Set<CGWindowID> = []
    /// When that filter took effect, in mach time. No frame is safe before the
    /// first one has.
    public private(set) var committedAt: UInt64?
    /// Windows seen needing to be hidden that no filter has covered yet.
    public private(set) var uncovered: Set<CGWindowID> = []
    /// Frames composed up to this time may show a window that closed before any filter
    /// covered it.
    public private(set) var unsafeUntil: UInt64 = 0
    /// When the window list was last read.
    public private(set) var lastLook: UInt64?

    /// A window open between two looks further apart than this could go unseen, so nothing
    /// composed during that time can be vouched for. Looks are 200 ms apart when all's well.
    /// This is what makes the promise hold when the Mac is too busy to keep to that: a window
    /// open for at least this long is either seen, or the frames that could show it are lost.
    public static let longestGapBetweenLooks: TimeInterval = 0.25

    private static let longestGapInTicks: UInt64 = {
        var base = mach_timebase_info()
        mach_timebase_info(&base)
        return UInt64(longestGapBetweenLooks * 1e9) * UInt64(base.denom) / UInt64(base.numer)
    }()

    public init() {}

    /// Records that the window list was read just now.
    public mutating func noteLook(at now: UInt64) {
        if let lastLook, now > lastLook, now - lastLook > Self.longestGapInTicks {
            markUnsafe(until: now)
        }
        lastLook = max(lastLook ?? 0, now)
    }

    /// Says that frames composed up to this time can't be vouched for.
    public mutating func markUnsafe(until time: UInt64) {
        unsafeUntil = max(unsafeUntil, time)
    }

    /// Records that a filter hiding `windows` has taken effect.
    public mutating func commit(_ windows: Set<CGWindowID>, at machTime: UInt64) {
        committed = windows
        committedAt = machTime
        uncovered.subtract(windows)
    }

    /// Takes note of what must be hidden right now, and returns any windows the filter
    /// doesn't cover.
    @discardableResult
    public mutating func observe(required: Set<CGWindowID>, now: UInt64) -> Set<CGWindowID> {
        let gone = uncovered.subtracting(required)
        if !gone.isEmpty {
            unsafeUntil = max(unsafeUntil, now)
            uncovered.subtract(gone)
        }
        let missing = required.subtracting(committed)
        uncovered.formUnion(missing)
        return missing
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

    public mutating func check(
        required: Set<CGWindowID>,
        frameDisplayTime: UInt64,
        now: UInt64 = mach_absolute_time()
    ) -> Verdict {
        guard let committedAt else { return .dropNoFilter }
        noteLook(at: now)
        if !observe(required: required, now: now).isEmpty {
            return .dropNeedsFilter(required)
        }
        return frameDisplayTime > committedAt && frameDisplayTime > unsafeUntil ? .allow : .dropFrameTooOld
    }
}
