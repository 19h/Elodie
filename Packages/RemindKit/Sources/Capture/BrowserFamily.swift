import Foundation

/// The kind of browser an app is, which decides how to read its URL and how to
/// spot its private windows.
public enum BrowserFamily: Sendable, Equatable {
    case chromium
    /// Chromium-based, but marks private windows differently.
    case arc
    case webkit
    case gecko
}

extension BrowserFamily {
    /// Classifies an app by how it's built rather than from a fixed list, so new
    /// and renamed browsers such as Brave Origin Nightly are handled.
    ///
    /// A Chromium browser has a renderer helper and handles web links. Electron
    /// and CEF apps also have the helper, but they use their own framework and
    /// don't usually claim web links, so they're correctly left out.
    public static func detect(bundleID: String?, bundleURL: URL?) -> BrowserFamily? {
        if let bundleID {
            if bundleID.hasPrefix("com.apple.Safari") { return .webkit }
            if bundleID.hasPrefix("company.thebrowser.") { return .arc }
        }
        guard let bundleURL else { return nil }
        let contents = bundleURL.appending(path: "Contents", directoryHint: .isDirectory)
        let files = FileManager.default

        guard handlesWebLinks(contents: contents) else { return nil }

        if files.fileExists(atPath: contents.appending(path: "MacOS/XUL").path) {
            return .gecko
        }

        let frameworks = contents.appending(path: "Frameworks", directoryHint: .isDirectory)
        guard let names = try? files.contentsOfDirectory(atPath: frameworks.path) else { return nil }
        let framework = names.first { $0.hasSuffix(" Framework.framework") }
        guard let framework,
              framework != "Electron Framework.framework",
              framework != "Chromium Embedded Framework.framework"
        else { return nil }
        return hasRendererHelper(frameworks: frameworks, framework: framework) ? .chromium : nil
    }

    private static func handlesWebLinks(contents: URL) -> Bool {
        let plist = contents.appending(path: "Info.plist")
        guard let info = NSDictionary(contentsOf: plist),
              let types = info["CFBundleURLTypes"] as? [[String: Any]]
        else { return false }
        return types.contains { type in
            let schemes = type["CFBundleURLSchemes"] as? [String] ?? []
            return schemes.contains("https") || schemes.contains("http")
        }
    }

    /// Looks for `<Name> Helper (Renderer).app`, which sits under the framework.
    private static func hasRendererHelper(frameworks: URL, framework: String) -> Bool {
        let root = frameworks.appending(path: framework, directoryHint: .isDirectory)
        let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: nil,
            options: [.skipsPackageDescendants]
        )
        while let url = enumerator?.nextObject() as? URL {
            if url.lastPathComponent.hasSuffix("Helper (Renderer).app") {
                return true
            }
            if enumerator?.level ?? 0 > 5 {
                enumerator?.skipDescendants()
            }
        }
        return false
    }
}
