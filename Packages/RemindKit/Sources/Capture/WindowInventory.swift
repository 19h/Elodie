import AppKit
import CoreGraphics

/// Reads which windows are on screen, and identifies the apps that own them.
public final class WindowInventory: @unchecked Sendable {
    private let lock = NSLock()
    private var identities: [pid_t: AppIdentity] = [:]

    public init() {}

    /// Windows on screen, front to back. Titles need the Screen Recording permission.
    public func onScreenWindows() -> [WindowInfo] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
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
        lock.withLock { identities[pid] = identity }
        return identity
    }

    /// Forgets a process, because macOS can reuse its ID after it exits.
    public func forget(_ pid: pid_t) {
        lock.withLock { _ = identities.removeValue(forKey: pid) }
    }
}
