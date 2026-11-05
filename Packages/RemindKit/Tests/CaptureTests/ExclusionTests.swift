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

@Suite struct Gate {
    @Test func nothingIsAllowedBeforeTheFirstFilter() {
        var gate = ExclusionGate()
        #expect(gate.check(required: [], frameDisplayTime: 100, now: 100) == .dropNoFilter)
    }

    @Test func aFrameAfterTheFilterIsAllowed() {
        var gate = ExclusionGate()
        gate.commit([1, 2], at: 100)
        #expect(gate.check(required: [1], frameDisplayTime: 101, now: 210) == .allow)
        #expect(gate.check(required: [], frameDisplayTime: 101, now: 210) == .allow)
    }

    /// The window opened, and the filter hasn't caught up. This is the race the
    /// gate exists for.
    @Test func aNewPrivateWindowDropsFramesUntilTheFilterCoversIt() {
        var gate = ExclusionGate()
        gate.commit([], at: 100)
        #expect(gate.check(required: [7], frameDisplayTime: 200, now: 210) == .dropNeedsFilter([7]))
        gate.commit([7], at: 300)
        // Composed before the new filter applied, so it may still show the window.
        #expect(gate.check(required: [7], frameDisplayTime: 250, now: 310) == .dropFrameTooOld)
        #expect(gate.check(required: [7], frameDisplayTime: 300, now: 310) == .dropFrameTooOld)
        #expect(gate.check(required: [7], frameDisplayTime: 301, now: 310) == .allow)
    }

    @Test func ordinaryWindowsCostNoFrames() {
        // Required is what must be hidden, so an ordinary window never appears in it.
        var gate = ExclusionGate()
        gate.commit([7], at: 100)
        #expect(gate.check(required: [7], frameDisplayTime: 200, now: 210) == .allow)
    }

    /// The race spike 2 caught in real use. The window was seen, and it closed before the
    /// filter caught up, so by the time a frame showing it is checked, it's no longer
    /// on screen to warn anyone.
    @Test func aWindowThatClosesBeforeTheFilterCoversItCantLeak() {
        var gate = ExclusionGate()
        gate.commit([], at: 100)
        #expect(gate.check(required: [7], frameDisplayTime: 200, now: 210) == .dropNeedsFilter([7]))
        // Now it's gone, and this frame was composed while it was still open.
        #expect(gate.check(required: [], frameDisplayTime: 220, now: 230) == .dropFrameTooOld)
        // Composed before anyone noticed it had gone, so it can't be trusted either.
        #expect(gate.check(required: [], frameDisplayTime: 229, now: 240) == .dropFrameTooOld)
        // Composed after that, when the window was certainly gone.
        #expect(gate.check(required: [], frameDisplayTime: 231, now: 250) == .allow)
    }

    @Test func theWatcherSeeingAWindowProtectsLaterFrames() {
        var gate = ExclusionGate()
        gate.commit([], at: 100)
        // Seen between frames.
        #expect(gate.observe(required: [7], now: 150) == [7])
        // Closed between frames, before any frame was checked.
        #expect(gate.observe(required: [], now: 180).isEmpty)
        // A frame composed while it was open.
        #expect(gate.check(required: [], frameDisplayTime: 160, now: 200) == .dropFrameTooOld)
        #expect(gate.check(required: [], frameDisplayTime: 181, now: 200) == .allow)
    }

    @Test func aCoveredWindowClosingCostsNothing() {
        var gate = ExclusionGate()
        gate.commit([], at: 100)
        _ = gate.check(required: [7], frameDisplayTime: 200, now: 210)
        gate.commit([7], at: 300)
        #expect(gate.check(required: [7], frameDisplayTime: 301, now: 310) == .allow)
        // The filter hid it the whole time, so its closing tells us nothing about frames.
        #expect(gate.check(required: [], frameDisplayTime: 305, now: 320) == .allow)
    }

    @Test func windowsThatClosedDoNotBlockAnything() {
        var gate = ExclusionGate()
        gate.commit([7, 8], at: 100)
        #expect(gate.check(required: [8], frameDisplayTime: 200, now: 210) == .allow)
    }
}

/// A window can only be caught by looking while it's open, so frames from a stretch with no
/// looks can't be vouched for. Spike 2 caught a private window reaching the encoder when the
/// watcher ran 349 ms late on a busy Mac.
@Suite struct LooksThatComeLate {
    /// About a second, far longer than the longest gap allowed, on any Mac's clock.
    private let long: UInt64 = {
        var base = mach_timebase_info()
        mach_timebase_info(&base)
        return 1_000_000_000 * UInt64(base.denom) / UInt64(base.numer)
    }()

    private func gate(firstLook: UInt64) -> ExclusionGate {
        var gate = ExclusionGate()
        gate.commit([], at: 1)
        gate.noteLook(at: firstLook)
        return gate
    }

    @Test func looksOnTimeAllowFrames() {
        var gate = gate(firstLook: 100)
        gate.noteLook(at: 100 + long / 5)
        let frame = 100 + long / 5 + 10
        #expect(gate.check(required: [], frameDisplayTime: frame, now: frame + 5) == .allow)
    }

    @Test func framesFromALateLooksGapAreDropped() {
        var gate = gate(firstLook: 100)
        // The watcher finally runs, a second after the last look.
        gate.noteLook(at: 100 + long)
        // Composed during the gap, so it could show something nobody looked for.
        #expect(gate.check(required: [], frameDisplayTime: 100 + long / 2, now: 100 + long + 5) == .dropFrameTooOld)
        // Once looks are back on time, frames are fine again.
        #expect(gate.check(required: [], frameDisplayTime: 100 + long + 10, now: 100 + long + 15) == .allow)
    }

    /// The frame's own check counts as a look, so it can close the gap by itself.
    @Test func aFrameArrivingAtTheEndOfAGapIsDropped() {
        var gate = gate(firstLook: 100)
        let frame = 100 + long
        #expect(gate.check(required: [], frameDisplayTime: frame, now: frame + 5) == .dropFrameTooOld)
    }

    /// A window seen in the list that closed before its details could be read.
    @Test func framesFromBeforeAWindowVanishedAreDropped() {
        var gate = gate(firstLook: 100)
        gate.markUnsafe(until: 200)
        #expect(gate.check(required: [], frameDisplayTime: 150, now: 210) == .dropFrameTooOld)
        #expect(gate.check(required: [], frameDisplayTime: 205, now: 210) == .allow)
    }

    @Test func aClockThatSeemsToGoBackwardsChangesNothing() {
        var gate = gate(firstLook: 1_000)
        gate.noteLook(at: 500)
        #expect(gate.lastLook == 1_000)
        #expect(gate.unsafeUntil == 0)
    }
}
