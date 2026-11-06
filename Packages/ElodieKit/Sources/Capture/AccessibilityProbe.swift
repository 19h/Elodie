import ApplicationServices
import Foundation

/// What Accessibility could read about the front window.
public struct FrontWindowInfo: Sendable, Equatable {
    public var title: String?
    public var url: String?
    /// The browser itself marked this window as private, which doesn't depend on language.
    public var isMarkedPrivate: Bool

    public init(title: String? = nil, url: String? = nil, isMarkedPrivate: Bool = false) {
        self.title = title
        self.url = url
        self.isMarkedPrivate = isMarkedPrivate
    }
}

/// Reads the front window's title and URL through Accessibility.
///
/// Everything has a deadline, because an app that's hung or busy can leave a call
/// waiting for seconds, and this runs on the capture path. Only the title and
/// address bar are read. Page text comes from OCR.
public enum AccessibilityProbe {
    public enum Failure: Error, Equatable {
        case notTrusted
        case noFocusedWindow
        case timedOut
        /// The browser gave an error, so nothing can be said about its window.
        case failed
    }

    public static var isTrusted: Bool {
        AXIsProcessTrusted()
    }

    public static func frontWindow(
        pid: pid_t,
        family: BrowserFamily?,
        timeout: TimeInterval = 0.05
    ) -> Result<FrontWindowInfo, Failure> {
        guard isTrusted else { return .failure(.notTrusted) }
        let deadline = Date().addingTimeInterval(timeout)
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, Float(timeout))

        var windowValue: AnyObject?
        let status = AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &windowValue)
        switch status {
        case .success:
            break
        case .cannotComplete:
            return .failure(.timedOut)
        case .noValue, .attributeUnsupported:
            return .failure(.noFocusedWindow)
        default:
            return .failure(.failed)
        }
        guard let windowValue, CFGetTypeID(windowValue) == AXUIElementGetTypeID() else {
            return .failure(.noFocusedWindow)
        }
        let window = windowValue as! AXUIElement
        AXUIElementSetMessagingTimeout(window, Float(timeout))
        var info = FrontWindowInfo(title: string(window, kAXTitleAttribute))

        guard let family else { return .success(info) }

        info.isMarkedPrivate = PrivateWindowRules.isPrivate(
            identifier: string(window, kAXIdentifierAttribute),
            family: family
        )

        // Safari reports its page directly.
        if let document = string(window, kAXDocumentAttribute), !document.isEmpty {
            info.url = document
            return .success(info)
        }
        if family == .gecko {
            // Firefox doesn't expose its address bar cheaply.
            return .success(info)
        }
        info.url = findAddress(in: window, family: family, deadline: deadline)
        if info.url == nil, Date() > deadline {
            return .failure(.timedOut)
        }
        return .success(info)
    }

    private static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
            return nil
        }
        if let string = value as? String { return string }
        if let url = value as? URL { return url.absoluteString }
        return nil
    }

    private static func children(_ element: AXUIElement) -> [AXUIElement] {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value) == .success else {
            return []
        }
        return value as? [AXUIElement] ?? []
    }

    /// Breadth-first through the window for the address bar: the first text field
    /// in a toolbar. That's language-independent, unlike matching its label.
    private static func findAddress(
        in window: AXUIElement,
        family: BrowserFamily,
        deadline: Date
    ) -> String? {
        var queue = children(window)
        var visited = 0
        var inToolbar = Set<CFHashCode>()
        while !queue.isEmpty, visited < 200, Date() < deadline {
            let element = queue.removeFirst()
            visited += 1
            let role = string(element, kAXRoleAttribute)
            if role == "AXWebArea", let url = string(element, kAXURLAttribute) {
                return url
            }
            let isToolbar = role == kAXToolbarRole as String
            if role == kAXTextFieldRole as String, inToolbar.contains(CFHash(element)),
               let value = string(element, kAXValueAttribute), !value.isEmpty {
                return value
            }
            let kids = children(element)
            if isToolbar || inToolbar.contains(CFHash(element)) {
                kids.forEach { inToolbar.insert(CFHash($0)) }
            }
            queue.append(contentsOf: kids)
        }
        return nil
    }
}
