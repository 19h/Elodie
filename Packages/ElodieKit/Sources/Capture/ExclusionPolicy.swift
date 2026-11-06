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
