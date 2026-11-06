import Darwin

/// What could be read about the front window.
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

/// Why it couldn't be read.
public enum FrontWindowFailure: Error, Equatable, Sendable {
    /// Nothing is allowed to read other apps' windows, so only the window list is known.
    case notTrusted
    case noFocusedWindow
    case timedOut
    /// The browser gave an error, so nothing can be said about its window.
    case failed
}

/// Reads an app's front window. That takes Accessibility, which an App Store build can't use,
/// so whoever starts recording supplies this, and nothing in this package touches it.
public typealias FrontWindowReader = @Sendable (pid_t, BrowserFamily?) -> Result<FrontWindowInfo, FrontWindowFailure>
