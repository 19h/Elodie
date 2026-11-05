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

    /// Non-browsers can have any title they like.
    @Test func titlesOnlyMatterForBrowsers() {
        let policy = ExclusionPolicy(excludedBundleIDs: [])
        let required = policy.requiredExclusions(in: [window(30, pid: 3, title: "Plans - Incognito")]) {
            apps[$0] ?? AppIdentity(bundleID: nil, family: nil)
        }
        #expect(required.isEmpty)
    }
}

@Suite struct Gate {
    @Test func nothingIsAllowedBeforeTheFirstFilter() {
        #expect(ExclusionGate().check(required: [], frameDisplayTime: 100) == .dropNoFilter)
    }

    @Test func aFrameAfterTheFilterIsAllowed() {
        var gate = ExclusionGate()
        gate.commit([1, 2], at: 100)
        #expect(gate.check(required: [1], frameDisplayTime: 101) == .allow)
        #expect(gate.check(required: [], frameDisplayTime: 101) == .allow)
    }

    /// The window opened, and the filter hasn't caught up. This is the race the
    /// gate exists for.
    @Test func aNewPrivateWindowDropsFramesUntilTheFilterCoversIt() {
        var gate = ExclusionGate()
        gate.commit([], at: 100)
        #expect(gate.check(required: [7], frameDisplayTime: 200) == .dropNeedsFilter([7]))
        gate.commit([7], at: 300)
        // Composed before the new filter applied, so it may still show the window.
        #expect(gate.check(required: [7], frameDisplayTime: 250) == .dropFrameTooOld)
        #expect(gate.check(required: [7], frameDisplayTime: 300) == .dropFrameTooOld)
        #expect(gate.check(required: [7], frameDisplayTime: 301) == .allow)
    }

    @Test func ordinaryWindowsCostNoFrames() {
        // Required is what must be hidden, so an ordinary window never appears in it.
        var gate = ExclusionGate()
        gate.commit([7], at: 100)
        #expect(gate.check(required: [7], frameDisplayTime: 200) == .allow)
    }

    @Test func windowsThatClosedDoNotBlockAnything() {
        var gate = ExclusionGate()
        gate.commit([7, 8], at: 100)
        #expect(gate.check(required: [8], frameDisplayTime: 200) == .allow)
    }
}
