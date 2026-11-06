import AppKit
import CoreGraphics

/// Reads which windows are on screen, and identifies the apps that own them.
public final class WindowInventory: @unchecked Sendable {
    private let lock = NSLock()
    private var identities: [pid_t: AppIdentity] = [:]

    public init() {}

    /// Windows on screen, front to back. Titles need the Screen Recording permission.
    public func onScreenWindows() -> [WindowInfo] {
        windows(options: [.optionOnScreenOnly, .excludeDesktopElements])
    }

    /// The same, with the desktop behind them, which is everything a picture of the screen shows.
    public func onScreenWindowsAndDesktop() -> [WindowInfo] {
        windows(options: [.optionOnScreenOnly])
    }

    private func windows(options: CGWindowListOption) -> [WindowInfo] {
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[CFString: Any]] else {
            return []
        }
        return list.compactMap { entry in
            guard let id = entry[kCGWindowNumber] as? CGWindowID,
                  let owner = entry[kCGWindowOwnerPID] as? pid_t
            else { return nil }
            var bounds = CGRect.zero
            if let dictionary = entry[kCGWindowBounds] as? NSDictionary as CFDictionary? {
                CGRectMakeWithDictionaryRepresentation(dictionary, &bounds)
            }
            return WindowInfo(
                id: id,
                ownerPID: owner,
                title: entry[kCGWindowName] as? String,
                layer: entry[kCGWindowLayer] as? Int ?? 0,
                bounds: bounds
            )
        }
    }

    /// Every window, including those on other Spaces and minimized ones.
    public func allWindows() -> [WindowInfo] {
        windows(options: [.optionAll, .excludeDesktopElements])
    }

    /// Identifies a process, caching the answer because reading a bundle is slow.
    public func identify(_ pid: pid_t) -> AppIdentity {
        if let known = lock.withLock({ identities[pid] }) {
            return known
        }
        let app = NSRunningApplication(processIdentifier: pid)
        let bundleID = app?.bundleIdentifier
        let identity = AppIdentity(
            bundleID: bundleID,
            family: BrowserFamily.detect(bundleID: bundleID, bundleURL: app?.bundleURL)
        )
        // An app still launching may not be identifiable yet, so that isn't remembered.
        if bundleID != nil {
            lock.withLock { identities[pid] = identity }
        }
        return identity
    }

    /// Forgets processes with no windows, because macOS can reuse an ID after a process
    /// exits, and an excluded app mustn't be mistaken for another.
    public func forgetProcesses(except running: Set<pid_t>) {
        lock.withLock {
            identities = identities.filter { running.contains($0.key) }
        }
    }

    /// Forgets a process, because macOS can reuse its ID after it exits.
    public func forget(_ pid: pid_t) {
        lock.withLock { _ = identities.removeValue(forKey: pid) }
    }
}
