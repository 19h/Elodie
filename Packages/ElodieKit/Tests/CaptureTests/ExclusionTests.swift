import Darwin
import Capture
import CoreGraphics
import Foundation
import Testing

@Suite struct BrowserDetection {
    private func family(_ path: String, id: String? = nil) throws -> BrowserFamily? {
        let url = URL(filePath: path)
        try #require(FileManager.default.fileExists(atPath: path), "\(path) isn't installed")
        let bundleID = id ?? Bundle(url: url)?.bundleIdentifier
        return BrowserFamily.detect(bundleID: bundleID, bundleURL: url)
    }

    // These read real installed apps, which is the point: a structural rule has to
    // work on real bundles. They're disabled when an app isn't installed.
    @Test(.enabled(if: FileManager.default.fileExists(atPath: "/Applications/Brave Origin Nightly.app")), arguments: [
        "/Applications/Google Chrome.app",
        "/Applications/Google Chrome Canary.app",
        "/Applications/Brave Browser Nightly.app",
        "/Applications/Brave Origin Nightly.app",
    ])
    func chromiumBrowsersAreRecognisedByStructure(path: String) throws {
        #expect(try family(path) == .chromium)
    }

    @Test(.enabled(if: FileManager.default.fileExists(atPath: "/Applications/Firefox.app")))
    func firefoxIsGecko() throws {
        #expect(try family("/Applications/Firefox.app") == .gecko)
    }

    @Test func safariIsWebKit() throws {
        #expect(BrowserFamily.detect(bundleID: "com.apple.Safari", bundleURL: nil) == .webkit)
        #expect(BrowserFamily.detect(bundleID: "com.apple.SafariTechnologyPreview", bundleURL: nil) == .webkit)
    }

    @Test func arcIsItsOwnCase() {
        #expect(BrowserFamily.detect(bundleID: "company.thebrowser.Browser", bundleURL: nil) == .arc)
    }

    // Electron apps have the same helper, and treating them as browsers would apply
    // private-window rules to them.
    @Test(.enabled(if: FileManager.default.fileExists(atPath: "/Applications/Discord.app")),
          arguments: ["/Applications/Discord.app", "/Applications/Claude.app", "/Applications/GitKraken.app"])
    func electronAppsAreNotBrowsers(path: String) throws {
        #expect(try family(path) == nil)
    }

    // These handle web links but aren't browsers.
    @Test(.enabled(if: FileManager.default.fileExists(atPath: "/Applications/Cyberduck.app")),
          arguments: ["/Applications/Cyberduck.app", "/Applications/Infuse.app"])
    func linkHandlersThatAreNotBrowsersAreLeftOut(path: String) throws {
        #expect(try family(path) == nil)
    }

    @Test func aMissingBundleIsNotABrowser() {
        #expect(BrowserFamily.detect(bundleID: "x.y", bundleURL: URL(filePath: "/nonexistent.app")) == nil)
        #expect(BrowserFamily.detect(bundleID: nil, bundleURL: nil) == nil)
    }
}

@Suite struct PrivateWindows {
    @Test(arguments: [
        "Wikipedia - Google Chrome - Incognito",
        "Wikipedia - Google Chrome - Inkognito",
        "Wikipedia - Brave (Private)",
        "Wikipedia - Brave (Privat)",
        "Some Page - Brave Origin Nightly (Private)",
        "Wikipedia - Microsoft Edge - InPrivate",
        "Seite - Vivaldi - Privat",
    ])
    func chromiumPrivateTitles(title: String) {
        #expect(PrivateWindowRules.isPrivate(title: title, family: .chromium))
    }

    @Test(arguments: [
        "Wikipedia - Google Chrome",
        "Wikipedia - Brave",
        "New Tab",
        // Pages about private browsing, in ordinary windows.
        "How to use Incognito mode - Google Chrome",
        "Private Browsing explained - Brave",
        "Incognito - Wikipedia - Brave",
    ])
    func chromiumOrdinaryTitles(title: String) {
        #expect(!PrivateWindowRules.isPrivate(title: title, family: .chromium))
    }

    @Test(arguments: [
        ("Apple, Private Browsing", BrowserFamily.webkit),
        ("Apple — Privates Surfen", .webkit),
        ("Wikipedia — Mozilla Firefox Private Browsing", .gecko),
        ("Wikipedia — Mozilla Firefox (Privater Modus)", .gecko),
    ])
    func webkitAndGeckoPrivateTitles(title: String, family: BrowserFamily) {
        #expect(PrivateWindowRules.isPrivate(title: title, family: family))
    }

    @Test(arguments: [
        ("Apple", BrowserFamily.webkit),
        ("Private Browsing guide on Apple Support", .webkit),
        ("Wikipedia — Mozilla Firefox", .gecko),
    ])
    func webkitAndGeckoOrdinaryTitles(title: String, family: BrowserFamily) {
        #expect(!PrivateWindowRules.isPrivate(title: title, family: family))
    }

    @Test func missingTitlesAreNotPrivate() {
        #expect(!PrivateWindowRules.isPrivate(title: nil, family: .chromium))
        #expect(!PrivateWindowRules.isPrivate(title: "", family: .webkit))
    }
}

@Suite struct Exclusion {
    private func window(_ id: CGWindowID, pid: pid_t, title: String? = nil) -> WindowInfo {
        WindowInfo(id: id, ownerPID: pid, title: title, layer: 0, bounds: .zero)
    }

    private let apps: [pid_t: AppIdentity] = [
        1: AppIdentity(bundleID: "com.example.bank", family: nil),
        2: AppIdentity(bundleID: "com.google.Chrome", family: .chromium),
        3: AppIdentity(bundleID: "com.example.notes", family: nil),
    ]

    @Test func excludedAppsAndPrivateWindowsAreRequired() {
        let policy = ExclusionPolicy(excludedBundleIDs: ["com.example.bank"])
        let required = policy.requiredExclusions(in: [
            window(10, pid: 1, title: "Accounts"),
            window(20, pid: 2, title: "News - Google Chrome"),
            window(21, pid: 2, title: "Secret - Google Chrome - Incognito"),
            window(30, pid: 3, title: "Notes"),
        ]) { apps[$0] ?? AppIdentity(bundleID: nil, family: nil) }
        #expect(required == [10, 21])
    }

    @Test func turningOffPrivateExclusionKeepsThoseWindows() {
        let policy = ExclusionPolicy(excludedBundleIDs: [], excludesPrivateWindows: false)
        let required = policy.requiredExclusions(in: [window(21, pid: 2, title: "x - Google Chrome - Incognito")]) {
            apps[$0] ?? AppIdentity(bundleID: nil, family: nil)
        }
        #expect(required.isEmpty)
    }

    /// A new window can exist for a moment before it has a title.
    @Test func aBrowserWindowWithNoTitleYetCountsAsPrivate() {
        let policy = ExclusionPolicy(excludedBundleIDs: [])
        var untitled = window(22, pid: 2, title: nil)
        untitled.bounds = CGRect(x: 0, y: 0, width: 800, height: 600)
        var tooltip = window(23, pid: 2, title: nil)
        tooltip.bounds = CGRect(x: 0, y: 0, width: 120, height: 30)
        var otherApp = window(31, pid: 3, title: nil)
        otherApp.bounds = CGRect(x: 0, y: 0, width: 800, height: 600)
        let required = policy.requiredExclusions(in: [untitled, tooltip, otherApp]) {
            apps[$0] ?? AppIdentity(bundleID: nil, family: nil)
        }
        #expect(required == [22])
    }

    /// Non-browsers can have any title they like.
    @Test func titlesOnlyMatterForBrowsers() {
        let policy = ExclusionPolicy(excludedBundleIDs: [])
        let required = policy.requiredExclusions(in: [window(30, pid: 3, title: "Plans - Incognito")]) {
            apps[$0] ?? AppIdentity(bundleID: nil, family: nil)
        }
        #expect(required.isEmpty)
    }
}

/// A picture holds only the windows it asked for, so what matters is what gets asked for, and
/// whether anything changed by the time the picture exists.
@Suite struct ChoosingWindows {
    private final class Screen: @unchecked Sendable {
        var windows: [WindowInfo]
        init(_ windows: [WindowInfo]) { self.windows = windows }
    }

    private let apps: [pid_t: AppIdentity] = [
        1: AppIdentity(bundleID: "com.brave.Browser", family: .chromium),
        2: AppIdentity(bundleID: "com.apple.Notes", family: nil),
        3: AppIdentity(bundleID: "com.example.secret", family: nil),
    ]

    private func window(_ id: CGWindowID, pid: pid_t, title: String?) -> WindowInfo {
        WindowInfo(id: id, ownerPID: pid, title: title, layer: 0, bounds: CGRect(x: 0, y: 0, width: 800, height: 600))
    }

    private func chooser(_ screen: Screen, excluding: Set<String> = []) -> WindowChooser {
        WindowChooser(
            policy: ExclusionPolicy(excludedBundleIDs: excluding),
            identify: { [apps] in apps[$0] ?? AppIdentity(bundleID: nil, family: nil) },
            readWindows: { screen.windows }
        )
    }

    @Test func privateWindowsAndExcludedAppsAreLeftOutOfThePicture() {
        let screen = Screen([
            window(10, pid: 1, title: "Plans - Brave (Private)"),
            window(11, pid: 2, title: "Notes"),
            window(12, pid: 3, title: "Secret"),
            window(13, pid: 1, title: "Plans - Brave"),
        ])
        #expect(chooser(screen, excluding: ["com.example.secret"]).windowsToCapture() == [11, 13])
    }

    /// The order is how the windows stack in the picture.
    @Test func windowsStayInFrontToBackOrder() {
        let screen = Screen([window(30, pid: 2, title: "a"), window(10, pid: 2, title: "b"), window(20, pid: 2, title: "c")])
        #expect(chooser(screen).windowsToCapture() == [30, 10, 20])
    }

    @Test func thisAppsOwnWindowsAreAlwaysLeftOut() {
        let own = ProcessInfo.processInfo.processIdentifier
        let screen = Screen([window(40, pid: own, title: "Timeline"), window(41, pid: 2, title: "Notes")])
        #expect(chooser(screen).windowsToCapture() == [41])
    }

    @Test func aTestCanAskForOneProcesssWindows() {
        let screen = Screen([window(50, pid: 2, title: "Notes"), window(51, pid: 3, title: "Other")])
        #expect(chooser(screen).windowsToCapture(ownedBy: 3) == [51])
    }

    /// Opened after the windows were chosen, so it isn't in the picture, and no frame is lost.
    @Test func aWindowOpeningAfterThePictureCostsNothing() {
        let screen = Screen([window(60, pid: 2, title: "Notes")])
        let chooser = chooser(screen)
        let captured = Set(chooser.windowsToCapture())
        screen.windows.insert(window(61, pid: 1, title: "New - Brave (Private)"), at: 0)
        #expect(chooser.check(captured: captured).isSafe)
        #expect(chooser.framesDropped == 0)
        #expect(chooser.windowsToCapture() == [60])
    }

    /// The one case left: chosen as ordinary, then its title gave it away.
    @Test func aWindowThatTurnsOutPrivateDropsThePicture() {
        let screen = Screen([window(70, pid: 1, title: "New Tab - Brave")])
        let chooser = chooser(screen)
        let captured = Set(chooser.windowsToCapture())
        #expect(captured == [70])
        screen.windows = [window(70, pid: 1, title: "New Tab - Brave (Private)")]
        #expect(!chooser.check(captured: captured).isSafe)
        #expect(chooser.framesDropped == 1)
    }

    @Test func excludingAnAppAppliesFromTheNextPicture() {
        let screen = Screen([window(80, pid: 2, title: "Notes")])
        let chooser = chooser(screen)
        let captured = Set(chooser.windowsToCapture())
        chooser.update(policy: ExclusionPolicy(excludedBundleIDs: ["com.apple.Notes"]))
        #expect(!chooser.check(captured: captured).isSafe)
        #expect(chooser.windowsToCapture().isEmpty)
    }

    @Test func aWindowWithNoTitleYetIsTreatedAsPrivate() {
        let screen = Screen([window(90, pid: 1, title: nil), window(91, pid: 2, title: nil)])
        #expect(chooser(screen).windowsToCapture() == [91])
    }
}
