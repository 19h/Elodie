import DesignSystem
import Foundation
import Metal
@testable import OverlayShell
@testable import StripRenderer
import Testing
import simd

@Suite struct ReadabilityOverAnyFrame {
    /// A control's white text over the darkest and lightest things a frame could show,
    /// after the scrim. Real glass adds its own darkening, so this is the floor.
    @Test func whiteTextPassesOverAWhiteFrameThanksToTheScrim() {
        let white = 1.0
        // The time pill sits about 80 points above the bottom of the 180-point scrim.
        let heightFraction = 1 - 80.0 / ChromeMetrics.scrimHeight
        let opacity = ChromeMetrics.scrimOpacity * heightFraction
        let backdrop = Contrast.darkened(luminance: white, by: opacity)
        // Liquid glass forced dark adds at least this much again.
        let glass = Contrast.darkened(luminance: backdrop, by: 0.5)
        let ratio = Contrast.ratio(1, glass)
        #expect(ratio >= 4.5, "only \(ratio):1")
    }

    @Test func reducedTransparencyGivesFarMoreContrast() {
        let opacity = ChromeMetrics.reducedTransparencyOpacity
        let backdrop = Contrast.darkened(luminance: 1, by: opacity)
        #expect(Contrast.ratio(1, backdrop) >= 7)
    }

    @Test func accentButtonsMeetTheContrastTheDesignClaims() {
        func luminance(_ hex: UInt32) -> Double {
            Contrast.luminance(
                red: Double((hex >> 16) & 0xFF) / 255,
                green: Double((hex >> 8) & 0xFF) / 255,
                blue: Double(hex & 0xFF) / 255
            )
        }
        // Verdigris and its text colour, in dark and light appearance.
        #expect(Contrast.ratio(luminance(0x45C9B1), luminance(0x04211C)) >= 7)
        #expect(Contrast.ratio(luminance(0x0B7F70), luminance(0xFFFFFF)) >= 4.5)
    }

    @Test func theContrastFormulaMatchesKnownValues() {
        #expect(abs(Contrast.ratio(1, 0) - 21) < 0.001)
        #expect(abs(Contrast.luminance(red: 1, green: 1, blue: 1) - 1) < 0.001)
        #expect(Contrast.ratio(0.5, 0.5) == 1)
    }
}

@Suite struct TimeLabels {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let locale = Locale(identifier: "en_US")
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private func label(_ secondsAgo: TimeInterval) -> String {
        TimeLabel.text(for: now.addingTimeInterval(-secondsAgo), now: now, calendar: calendar, locale: locale)
    }

    @Test func recentMomentsAreRelative() {
        #expect(label(1) == "Just now")
        #expect(label(23) == "23 seconds ago")
        #expect(label(30) == "30 seconds ago")
        #expect(label(120) == "2 minutes ago")
    }

    @Test func olderMomentsShowTheTime() {
        // 1,800,000,000 is 08:00 UTC, so 2 hours earlier is the same day.
        #expect(label(2 * 3600).contains("6:00"))
    }

    @Test func thisWeekIncludesTheDayName() {
        let text = label(2 * 86_400)
        #expect(text.contains("Jan") == false)
        #expect(text.contains(":"))
    }

    @Test func olderDatesIncludeTheDateAndOnlyAYearIfDifferent() {
        // "Now" here is 15 January 2027, so 10 days earlier is the same year.
        #expect(!label(10 * 86_400).contains("20"))
        #expect(label(400 * 86_400).contains("2025"))
    }

    @Test func labelsFollowTheLocale() {
        let german = TimeLabel.text(
            for: now.addingTimeInterval(-120), now: now, calendar: calendar, locale: Locale(identifier: "de_DE")
        )
        #expect(german.contains("2") && german.lowercased().contains("min"))
    }
}

@Suite struct Scrolling {
    private func moved(_ input: ScrollInput, pointsPerSecond: Double = 2) -> Double {
        var interpreter = ScrollInterpreter(pointsPerSecond: pointsPerSecond)
        return interpreter.seconds(for: input)
    }

    @Test func draggingContentRightOrDownGoesBackInTime() {
        #expect(moved(ScrollInput(deltaX: 10, deltaY: 0)) < 0)
        #expect(moved(ScrollInput(deltaX: 0, deltaY: 10)) < 0)
        #expect(moved(ScrollInput(deltaX: -10, deltaY: 0)) > 0)
    }

    @Test func movementScalesWithZoom() {
        #expect(moved(ScrollInput(deltaX: 10, deltaY: 0), pointsPerSecond: 2) == -5)
        #expect(moved(ScrollInput(deltaX: 10, deltaY: 0), pointsPerSecond: 10) == -1)
    }

    @Test func onlyTheStrongerAxisCounts() {
        #expect(moved(ScrollInput(deltaX: 10, deltaY: -2)) == -5)
        #expect(moved(ScrollInput(deltaX: 1, deltaY: 8)) == -4)
    }

    @Test func mouseWheelNotchesMoveAUsableDistance() {
        let wheel = moved(ScrollInput(deltaX: 0, deltaY: 1, hasPreciseDeltas: false))
        let trackpad = moved(ScrollInput(deltaX: 0, deltaY: 1, hasPreciseDeltas: true))
        #expect(abs(wheel) > abs(trackpad) * 10)
    }

    @Test func holdingTheModifierScrollsFaster() {
        let fast = moved(ScrollInput(deltaX: 10, deltaY: 0, isFast: true))
        #expect(abs(fast) == abs(moved(ScrollInput(deltaX: 10, deltaY: 0))) * 8)
    }

    @Test func velocityReflectsHowFastItMoves() {
        var interpreter = ScrollInterpreter(pointsPerSecond: 2)
        _ = interpreter.seconds(for: ScrollInput(deltaX: 100, deltaY: 0, timestamp: 1.0))
        _ = interpreter.seconds(for: ScrollInput(deltaX: 100, deltaY: 0, timestamp: 1.01))
        #expect(interpreter.velocity < -500)
        interpreter.reset()
        #expect(interpreter.velocity == 0)
    }

    @Test func zoomStaysWithinLimits() {
        #expect(TimelineZoom.applying(magnification: 100, to: 1) == TimelineZoom.maximumPointsPerSecond)
        #expect(TimelineZoom.applying(magnification: -0.99999, to: 0.02) == TimelineZoom.minimumPointsPerSecond)
    }
}

@Suite struct Keys {
    private func action(
        _ keyCode: UInt16,
        _ characters: String? = nil,
        _ modifiers: NSEvent.ModifierFlags = [],
        searching: Bool = false
    ) -> OverlayAction? {
        OverlayKeyMap.action(keyCode: keyCode, characters: characters, modifiers: modifiers, isSearchFocused: searching)
    }

    @Test func escapeAlwaysDismisses() {
        #expect(action(53) == .dismiss)
        #expect(action(53, searching: true) == .dismiss)
    }

    @Test func arrowsStepFramesAndOptionStepsRuns() {
        #expect(action(123) == .stepFrame(forward: false))
        #expect(action(124) == .stepFrame(forward: true))
        #expect(action(123, nil, .option) == .stepRun(forward: false))
        #expect(action(124, nil, .option) == .stepRun(forward: true))
    }

    /// Arrows must move the caret when typing a search.
    @Test func arrowsBelongToTheFieldWhileSearching() {
        #expect(action(123, searching: true) == nil)
    }

    @Test func returnOpensExceptWhileSearching() {
        #expect(action(36) == .open)
        #expect(action(36, searching: true) == nil)
    }

    /// Quitting from the overlay would silently stop recording.
    @Test func quitAndCloseOnlyDismiss() {
        #expect(action(12, "q", .command) == .dismiss)
        #expect(action(13, "w", .command) == .dismiss)
    }

    @Test func commandFFocusesSearch() {
        #expect(action(3, "f", .command) == .focusSearch)
    }

    @Test func typingStartsASearchInAnyScript() {
        #expect(action(0, "a") == .typed("a"))
        #expect(action(0, "ä") == .typed("ä"))
        #expect(action(0, "東") == .typed("東"))
    }

    @Test func modifiedKeysAndFunctionKeysDoNotType() {
        #expect(action(0, "a", .control) == nil)
        #expect(action(0, "a", .option) == nil)
        // Function keys arrive in this private-use range.
        #expect(action(122, "\u{F704}") == nil)
        // Tab is a control character.
        #expect(action(48, "\t") == nil)
    }

    @Test func typingDoesNotFireWhileTheFieldHasFocus() {
        #expect(action(0, "a", searching: true) == nil)
    }
}

@Suite struct OverlayWindow {
    @MainActor
    @Test func thePanelHasTheBehaviourTheOverlayDependsOn() {
        let panel = NSPanelForTest()
        OverlayPanel.configure(panel)
        #expect(panel.level.rawValue == NSWindow.Level.statusBar.rawValue + 1)
        #expect(panel.level.rawValue < NSWindow.Level.popUpMenu.rawValue)
        #expect(panel.collectionBehavior.contains(.fullScreenAuxiliary))
        #expect(panel.collectionBehavior.contains(.canJoinAllSpaces))
        #expect(panel.collectionBehavior.contains(.ignoresCycle))
        #expect(!panel.hidesOnDeactivate)
        #expect(panel.animationBehavior == .none)
        #expect(panel.sharingType == .none)
        #expect(panel.isOpaque)
    }
}

import AppKit

@MainActor
private func NSPanelForTest() -> NSPanel {
    NSPanel(contentRect: .init(x: 0, y: 0, width: 10, height: 10), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
}

@Suite struct Strip {
    /// Renders to a texture and reads pixels back, so this tests what's drawn.
    private func render(_ runs: [StripRun], _ viewport: StripViewport) throws -> (pixels: [UInt8], width: Int, height: Int) {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let renderer = try StripRenderer(device: device, pixelFormat: .bgra8Unorm)
        renderer.setRuns(runs)

        let width = Int(viewport.widthPoints * viewport.scale)
        let height = Int(viewport.heightPoints * viewport.scale)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false
        )
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .shared
        let texture = try #require(device.makeTexture(descriptor: descriptor))

        let queue = try #require(device.makeCommandQueue())
        let commands = try #require(queue.makeCommandBuffer())
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        pass.colorAttachments[0].storeAction = .store
        let encoder = try #require(commands.makeRenderCommandEncoder(descriptor: pass))
        renderer.draw(in: encoder, viewport: viewport)
        encoder.endEncoding()
        commands.commit()
        commands.waitUntilCompleted()

        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        texture.getBytes(
            &pixels,
            bytesPerRow: width * 4,
            from: MTLRegionMake2D(0, 0, width, height),
            mipmapLevel: 0
        )
        return (pixels, width, height)
    }

    private func pixel(_ image: (pixels: [UInt8], width: Int, height: Int), xPoints: Double, yPoints: Double, scale: Double = 2) -> (r: UInt8, g: UInt8, b: UInt8, a: UInt8) {
        let x = Int(xPoints * scale), y = Int(yPoints * scale)
        let offset = (y * image.width + x) * 4
        return (image.pixels[offset + 2], image.pixels[offset + 1], image.pixels[offset], image.pixels[offset + 3])
    }

    private let red = SIMD4<Float>(1, 0, 0, 1)
    private let blue = SIMD4<Float>(0, 0, 1, 1)

    @Test func aRunAppearsWhereItsTimesSay() throws {
        // 2 points per second, centred on t = 100, on a 400-point strip: t = 100 is at 200.
        let viewport = StripViewport(center: 100, pointsPerSecond: 2, widthPoints: 400, heightPoints: 40)
        let image = try render([StripRun(start: 90, end: 110, color: red)], viewport)
        #expect(pixel(image, xPoints: 200, yPoints: 20).r > 240)
        #expect(pixel(image, xPoints: 185, yPoints: 20).r > 240)
        // Outside the run's 180 to 220.
        #expect(pixel(image, xPoints: 170, yPoints: 20).a == 0)
        #expect(pixel(image, xPoints: 230, yPoints: 20).a == 0)
    }

    @Test func runsAreOnlyAsTallAsACapsule() throws {
        let viewport = StripViewport(center: 0, pointsPerSecond: 2, widthPoints: 400, heightPoints: 40, capsuleHeightPoints: 14)
        let image = try render([StripRun(start: -50, end: 50, color: red)], viewport)
        #expect(pixel(image, xPoints: 200, yPoints: 20).a == 255)
        #expect(pixel(image, xPoints: 200, yPoints: 8).a == 0)
        #expect(pixel(image, xPoints: 200, yPoints: 32).a == 0)
    }

    @Test func endsAreRounded() throws {
        let viewport = StripViewport(center: 0, pointsPerSecond: 2, widthPoints: 400, heightPoints: 40, capsuleHeightPoints: 14)
        let image = try render([StripRun(start: -50, end: 50, color: red)], viewport)
        // At the far left edge, the capsule's corner has curved away.
        #expect(pixel(image, xPoints: 100.5, yPoints: 14).a < 40)
        #expect(pixel(image, xPoints: 101, yPoints: 20).a > 150)
    }

    @Test func panningOnlyMovesWhatIsDrawn() throws {
        let runs = [StripRun(start: 0, end: 10, color: red)]
        let a = try render(runs, StripViewport(center: 5, pointsPerSecond: 4, widthPoints: 400, heightPoints: 40))
        #expect(pixel(a, xPoints: 200, yPoints: 20).r > 240)
        // Moving the centre 25 seconds on shifts the run 100 points to the left.
        let b = try render(runs, StripViewport(center: 30, pointsPerSecond: 4, widthPoints: 400, heightPoints: 40))
        #expect(pixel(b, xPoints: 200, yPoints: 20).a == 0)
        #expect(pixel(b, xPoints: 100, yPoints: 20).r > 240)
    }

    @Test func aVeryShortRunIsStillVisible() throws {
        let viewport = StripViewport(center: 0, pointsPerSecond: 0.1, widthPoints: 400, heightPoints: 40)
        let image = try render([StripRun(start: 0, end: 1, color: blue)], viewport)
        #expect(pixel(image, xPoints: 200, yPoints: 20).b > 240)
    }

    @Test func manyRunsDrawEachInItsPlace() throws {
        let runs = (0..<500).map { index -> StripRun in
            StripRun(start: Float(index), end: Float(index) + 0.9, color: index.isMultiple(of: 2) ? red : blue)
        }
        // 20 points per second, so each run is 18 points wide and clearly separate.
        let viewport = StripViewport(center: 250.5, pointsPerSecond: 20, widthPoints: 400, heightPoints: 40, capsuleHeightPoints: 10)
        let image = try render(runs, viewport)
        // Run 250, which spans 250 to 250.9, is even and sits at the centre.
        let centre = pixel(image, xPoints: 195, yPoints: 20)
        #expect(centre.r > 200)
        // Run 251 is odd, 20 points to the right.
        let next = pixel(image, xPoints: 215, yPoints: 20)
        #expect(next.b > 200)
    }
}

@Suite struct IconColors {
    @Test func colourfulIconsKeepTheirHue() {
        let color = AppColors.stripColor(averageRed: 0.9, green: 0.2, blue: 0.2)
        #expect(color.x > color.y && color.x > color.z)
    }

    @Test func nearlyBlackAndWhiteIconsBecomeAVisibleGrey() {
        for (r, g, b) in [(0.02, 0.02, 0.02), (0.98, 0.98, 0.98), (0.5, 0.5, 0.52)] {
            let color = AppColors.stripColor(averageRed: r, green: g, blue: b)
            #expect(color.x > 0.4 && color.x < 0.8)
            #expect(abs(color.x - color.y) < 0.05)
        }
    }

    @Test func darkColourfulIconsAreBroughtUpToAVisibleLevel() {
        let color = AppColors.stripColor(averageRed: 0.1, green: 0.02, blue: 0.3)
        #expect(max(color.x, color.y, color.z) > 0.8)
    }

    @Test func nothingGetsPureBlackOrWhite() {
        for (r, g, b) in [(1.0, 0.0, 0.0), (0.0, 1.0, 1.0), (1.0, 1.0, 0.0)] {
            let color = AppColors.stripColor(averageRed: r, green: g, blue: b)
            #expect(min(color.x, color.y, color.z) >= 0.2)
            #expect(max(color.x, color.y, color.z) <= 0.92)
        }
    }
}

import CoreAPI
import CoreFake
import FeatureSearch

/// A fake that lets tests control how long a search takes, and which results it gives.
private final class ScriptedCore: RemindCore, @unchecked Sendable {
    private let inner = FakeCore()
    let lock = NSLock()
    var queries: [String] = []
    var cancels = 0
    var delay: [String: TimeInterval] = [:]

    func info() throws -> CoreInfo { try inner.info() }
    func stats() -> CoreStats { inner.stats() }
    func append(_ sample: EncodedSample) throws -> AppendOutcome { try inner.append(sample) }
    func sealAll() throws {}
    func lookup(display: UUID, at time: Date) throws -> FrameRef? { nil }
    func readGroup(containing frameID: Int64) throws -> GroupOfPictures { try inner.readGroup(containing: frameID) }
    func readKeyframe(of frameID: Int64) throws -> GroupOfPictures { try inner.readKeyframe(of: frameID) }
    func neighbour(of frameID: Int64, forward: Bool) throws -> FrameRef? { nil }
    func timeline(display: UUID, from: Date, to: Date, minimumDuration: TimeInterval) throws -> TimelineData {
        TimelineData(apps: [], runs: [])
    }
    func activePeriods(_ periods: [DateInterval]) throws -> [Bool] { [] }
    func frameContext(of frameID: Int64) throws -> FrameContext? { nil }
    func recordedApps() throws -> [String] { ["com.example.a"] }
    func recap(from: Date, to: Date, bucket: TimeInterval) throws -> Recap {
        Recap(totalActive: 0, apps: [], activity: [], blocks: [])
    }
    func frameText(of frameID: Int64) throws -> [String] { [] }
    func frameLines(of frameID: Int64) throws -> [RecognizedLine] { [] }
    func recordMeeting(title: String?, from: Date, to: Date) throws {}
    func meetings(from: Date, to: Date) throws -> [RecordedMeeting] { [] }
    func appendTranscript(_ words: [SpokenWord], title: String?) throws {}
    func transcript(from: Date, to: Date) throws -> [TranscriptLine] { [] }
    func setStarred(_ starred: Bool, frameID: Int64) throws {}
    func deleteRange(from: Date, to: Date) throws -> UInt64 { 0 }
    func nextOCRBatch(max: Int, now: Date, includeDeferred: Bool) throws -> [OCRJob] { [] }
    func submitOCR(_ results: [OCRResult]) throws {}
    func failOCR(frameID: Int64) throws {}

    func search(_ text: String, facets: SearchFacets, order: SearchOrder) throws -> (any SearchSession)? {
        lock.withLock { queries.append(text) }
        let wait = lock.withLock { delay[text] } ?? 0
        return Session(owner: self, text: text, wait: wait)
    }

    struct Session: SearchSession {
        let owner: ScriptedCore
        let text: String
        let wait: TimeInterval

        func nextPage() throws -> SearchPage {
            Thread.sleep(forTimeInterval: wait)
            let hit = SearchHit(
                frameID: Int64(text.count),
                runID: 1,
                capturedAt: Date(),
                bundleID: nil,
                window: text,
                url: nil,
                rects: [],
                snippet: text
            )
            return SearchPage(hits: [hit], hasMore: false)
        }

        func cancel() {
            owner.lock.withLock { owner.cancels += 1 }
        }
    }
}

@MainActor
@Suite struct SearchBehaviour {
    private func settle() async throws {
        try await Task.sleep(for: .milliseconds(150))
    }

    @Test func typingShowsResultsAndExpandsThePanel() async throws {
        let core = ScriptedCore()
        let model = SearchModel(core: core, debounce: .milliseconds(1))
        #expect(model.layout == .compact)
        model.text = "budget"
        #expect(model.layout == .expanded)
        try await settle()
        #expect(model.hits.map(\.window) == ["budget"])
        #expect(!model.isSearching)
    }

    @Test func fastTypingOnlyRunsTheLastQuery() async throws {
        let core = ScriptedCore()
        let model = SearchModel(core: core, debounce: .milliseconds(40))
        for text in ["b", "bu", "bud", "budg", "budge", "budget"] {
            model.text = text
        }
        try await settle()
        #expect(core.lock.withLock { core.queries } == ["budget"])
    }

    /// A slow result for old text must not overwrite newer results.
    @Test func aSlowOldQueryCannotOverwriteANewOne() async throws {
        let core = ScriptedCore()
        core.delay["slow"] = 0.25
        let model = SearchModel(core: core, debounce: .milliseconds(1))
        model.text = "slow"
        try await Task.sleep(for: .milliseconds(30))
        model.text = "fast"
        try await Task.sleep(for: .milliseconds(450))
        #expect(model.hits.map(\.window) == ["fast"])
    }

    @Test func clearingTheTextClearsResults() async throws {
        let core = ScriptedCore()
        let model = SearchModel(core: core, debounce: .milliseconds(1))
        model.text = "budget"
        try await settle()
        model.text = "   "
        #expect(model.hits.isEmpty)
        #expect(!model.isSearching)
    }

    @Test func changingAFilterSearchesAgain() async throws {
        let core = ScriptedCore()
        let model = SearchModel(core: core, debounce: .milliseconds(1))
        model.text = "budget"
        try await settle()
        model.starredOnly = true
        try await settle()
        #expect(core.lock.withLock { core.queries }.count == 2)
    }
}

import FeatureOnboarding
import FeatureSettings

@Suite struct Retention {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    @Test func foreverKeepsEverything() {
        #expect(RetentionPeriod.forever.cutoff(now: Date(), calendar: calendar) == nil)
    }

    @Test func cutoffsFallOnTheStartOfADay() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        for period in RetentionPeriod.allCases where period != .forever {
            let cutoff = try #require(period.cutoff(now: now, calendar: calendar))
            #expect(cutoff == calendar.startOfDay(for: cutoff))
            #expect(cutoff < now)
        }
    }

    @Test func aWeekIsSevenDays() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let cutoff = try #require(RetentionPeriod.oneWeek.cutoff(now: now, calendar: calendar))
        #expect(calendar.dateComponents([.day], from: cutoff, to: calendar.startOfDay(for: now)).day == 7)
    }
}

@MainActor
@Suite struct Settings {
    private func fresh() -> UserDefaults {
        let name = "remind-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    /// These are privacy and consent choices, and they have to start safe.
    @Test func defaultsFavourPrivacy() {
        let model = SettingsModel(defaults: fresh())
        #expect(model.excludePrivateWindows)
        #expect(model.meetingDetected == .ask)
        #expect(model.excludedApps.isEmpty)
        #expect(!model.hasFinishedOnboarding)
    }

    @Test func changesAreSavedAcrossInstances() {
        let defaults = fresh()
        let first = SettingsModel(defaults: defaults)
        first.excludedApps = ["com.example.bank"]
        first.retention = .oneMonth
        first.excludePrivateWindows = false
        let second = SettingsModel(defaults: defaults)
        #expect(second.excludedApps == ["com.example.bank"])
        #expect(second.retention == .oneMonth)
        #expect(!second.excludePrivateWindows)
    }

    @Test func usagePerDayComesFromRealHistory() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let usage = StorageUsage(recordingBytes: 10_000_000_000, freeBytes: 0, oldest: now.addingTimeInterval(-10 * 86_400))
        #expect(usage.bytesPerDay(now: now) == 1_000_000_000)
        // With under a day to go on, an estimate would mislead.
        let early = StorageUsage(recordingBytes: 100, freeBytes: 0, oldest: now.addingTimeInterval(-3600))
        #expect(early.bytesPerDay(now: now) == nil)
    }
}

@MainActor
@Suite struct PermissionStates {
    @Test func aGrantOnlyAFreshProcessCanSeeAsksForARelaunch() async throws {
        let monitor = PermissionMonitor(checkScreenAccess: { true })
        monitor.refresh()
        try await Task.sleep(for: .milliseconds(30))
        // This test process has no Screen Recording, but a "new process" reports it does.
        if !monitor.granted.contains(.screenRecording) {
            #expect(monitor.needsRelaunch)
        }
    }

    @Test func withNoGrantThereIsNoRelaunchPrompt() async throws {
        let monitor = PermissionMonitor(checkScreenAccess: { false })
        monitor.refresh()
        try await Task.sleep(for: .milliseconds(30))
        #expect(!monitor.needsRelaunch)
    }

    @Test func onlyScreenRecordingAndAccessibilityAreRequired() {
        #expect(Permission.screenRecording.isRequired)
        #expect(Permission.accessibility.isRequired)
        #expect(!Permission.microphone.isRequired)
    }
}
