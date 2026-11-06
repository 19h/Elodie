import CoreGraphics
import Foundation
import ImageIO
@preconcurrency import ScreenCaptureKit

/// Finds displays, and takes screenshots of this app's own windows.
public enum ScreenContent {
    /// Whether the screen is locked, or another user is on it. `CGSSessionScreenIsLocked` is
    /// undocumented, but there's no public way to ask. No answer counts as hidden.
    public static func isSessionHidden() -> Bool {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return true }
        return session["CGSSessionScreenIsLocked"] as? Bool ?? false
            || session[kCGSessionOnConsoleKey as String] as? Bool == false
    }

    /// A stable ID for a display. `CGDirectDisplayID` can change between boots.
    public static func stableID(of displayID: CGDirectDisplayID) -> UUID? {
        guard let uuid = CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue() else {
            return nil
        }
        let bytes = CFUUIDGetUUIDBytes(uuid)
        return UUID(uuid: (
            bytes.byte0, bytes.byte1, bytes.byte2, bytes.byte3,
            bytes.byte4, bytes.byte5, bytes.byte6, bytes.byte7,
            bytes.byte8, bytes.byte9, bytes.byte10, bytes.byte11,
            bytes.byte12, bytes.byte13, bytes.byte14, bytes.byte15
        ))
    }

    /// This process's windows on screen, largest first. The window server's own list is
    /// the authority on who owns what, and it needs no permission for one's own windows.
    private static func ownWindowsOnScreen() -> [CGWindowID] {
        let own = getpid()
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[CFString: Any]] ?? []
        func area(_ window: [CFString: Any]) -> CGFloat {
            guard let bounds = window[kCGWindowBounds] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds)
            else { return 0 }
            return rect.width * rect.height
        }
        return list
            .filter { ($0[kCGWindowOwnerPID] as? pid_t) == own }
            .sorted { area($0) > area($1) }
            .compactMap { ($0[kCGWindowNumber] as? NSNumber).map { CGWindowID($0.uint32Value) } }
    }

    /// Saves a screenshot of one of this app's windows. Glass and shadows render as they
    /// really do, which a view snapshot doesn't manage. It refuses anything else, because
    /// the current-process list can include windows that aren't ours, such as the desktop.
    public static func saveScreenshot(ofWindow windowID: CGWindowID, to url: URL) async throws {
        guard ownWindowsOnScreen().contains(windowID) else {
            throw DisplayCaptureError.displayNotFound(windowID)
        }
        let content = try await SCShareableContent.currentProcess
        guard let window = content.windows.first(where: { $0.windowID == windowID }) else {
            throw DisplayCaptureError.displayNotFound(windowID)
        }
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let configuration = SCStreamConfiguration()
        let scale = CGFloat(filter.pointPixelScale)
        configuration.width = Int(window.frame.width * scale)
        configuration.height = Int(window.frame.height * scale)
        configuration.showsCursor = false
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
            throw DisplayCaptureError.displayNotFound(windowID)
        }
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
    }

    /// Saves a screenshot of this app's largest window on screen.
    public static func saveScreenshotOfLargestOwnWindow(to url: URL) async throws {
        guard let largest = ownWindowsOnScreen().first else { throw DisplayCaptureError.displayNotFound(0) }
        try await saveScreenshot(ofWindow: largest, to: url)
    }
}
