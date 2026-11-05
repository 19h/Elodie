#if DEBUG
import AppKit
import Capture
import CoreAPI
import CoreFake
import CoreLive
import CoreVideo
import DesignSystem
import FeatureAsk
import FeatureMeetings
import FeatureOnboarding
import FeatureRecap
import FeatureSearch
import FeatureSettings
import FeatureTimeline
import FrameEngine
import Ingest
import OverlayShell
import SwiftUI
import TestKit

/// Shows one screen with fixture data, screenshots its own window, and exits. This is
/// how the interface can be checked with no one watching.
///
///     open -n Remind.app --args --scenario timeline --out /path/to/shot.png
enum Scenarios {
    @MainActor
    static func run(arguments: [String]) -> Never {
        func value(after flag: String) -> String? {
            arguments.firstIndex(of: flag).flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil }
        }
        let name = value(after: "--scenario") ?? "timeline"
        let output = value(after: "--out") ?? NSTemporaryDirectory() + "\(name).png"

        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)

        Task { @MainActor in
            do {
                try await show(name, output: URL(filePath: output))
                exit(0)
            } catch {
                try? "failed: \(error)".write(toFile: output + ".error", atomically: true, encoding: .utf8)
                exit(1)
            }
        }
        application.run()
        exit(0)
    }

    @MainActor
    private static func show(_ name: String, output: URL) async throws {
        switch name {
        case "onboarding-welcome":
            try await capture(onboarding(.welcome), size: NSSize(width: 800, height: 628), to: output)
        case "onboarding-how":
            try await capture(onboarding(.howItWorks), size: NSSize(width: 800, height: 628), to: output)
        case "onboarding-permissions":
            try await capture(onboarding(.permissions), size: NSSize(width: 800, height: 628), to: output)
        case "onboarding-ready":
            try await capture(onboarding(.ready), size: NSSize(width: 800, height: 628), to: output)
        case "recovery":
            try await capture(
                AnyView(RecoveryView(onRestore: { _ in .notAKey }, onStartOver: {}, onQuit: {})),
                size: NSSize(width: 560, height: 520),
                to: output
            )
        case "meeting-prompt":
            try await capture(
                AnyView(MeetingPrompt(appName: "Zoom", title: "Design review", onRecord: {}, onDismiss: {})),
                size: NSSize(width: 320, height: 300),
                to: output
            )
        case "notice-card":
            try await capture(
                AnyView(NoticeCard(
                    symbol: "rectangle.dashed.badge.record",
                    title: "Remind has stopped recording",
                    detail: "It needs Screen Recording permission. If it's already on, reopening Remind applies it.",
                    primary: "Open System Settings",
                    secondary: "Reopen Remind",
                    onPrimary: {},
                    onSecondary: {}
                )),
                size: NSSize(width: 300, height: 300),
                to: output
            )
        case "transcripts", "transcript", "recap", "ask":
            try await captureHistoryWindow(name, to: output)
        case "settings-general", "settings-screen", "settings-audio", "settings-meetings", "settings-storage", "settings-shortcuts":
            let tabs = ["general": SettingsTab.general, "screen": .screen, "audio": .audio, "meetings": .meetings, "storage": .storage, "shortcuts": .shortcuts]
            let window = ScenarioWindow(contentViewController: SettingsWindow.controller(
                model: SettingsModel(defaults: UserDefaults(suiteName: "remind-scenario")!),
                actions: PreviewActions(),
                shortcuts: AnyView(ShortcutsTab()),
                selecting: tabs[String(name.dropFirst("settings-".count))] ?? .general
            ))
            SettingsWindow.configure(window)
            window.center()
            present(window)
            try await Task.sleep(for: .milliseconds(900))
            try await screenshot(window, to: output)
        case "timeline", "search-compact", "search-expanded", "jump-to-date", "coach-marks",
             "slice-hover", "slice-selected", "slice-range", "slice-confirm", "timeline-zoom",
             "search-starred", "search-apps", "forget-confirm", "display-picker":
            try await captureOverlay(name, to: output)
        case "overlay-input":
            try await InputSelfTest.run(to: output)
        case "overlay-swipe":
            try await InputSelfTest.runSwipe(to: output)
        case "bench":
            try await Bench.run(to: output)
        case "contrast-white", "contrast-black", "contrast-noisy", "contrast-saturated":
            try await captureContrast(String(name.dropFirst("contrast-".count)), to: output)
        case "status-menu":
            try await captureStatusMenu(to: output)
        case "overflow-menu":
            try await captureOverflowMenu(to: output)
        default:
            throw ScenarioError.unknown(name)
        }
    }

    @MainActor
    private static func onboarding(_ step: OnboardingStep) -> AnyView {
        AnyView(OnboardingView(
            permissions: PermissionMonitor(checkScreenAccess: { false }),
            step: step,
            appIcon: NSApp.applicationIconImage,
            onRelaunch: {},
            onFinish: { _ in }
        ))
    }

    enum ScenarioError: Error {
        case unknown(String)
    }

    /// Screenshots a window through ScreenCaptureKit, so glass renders as it really does.
    /// An app can capture its own windows without Screen Recording permission.
    @MainActor
    private static func screenshot(_ window: NSWindow, to output: URL) async throws {
        try await ScreenContent.saveScreenshot(ofWindow: CGWindowID(window.windowNumber), to: output)
    }

    /// Shows a window without taking focus from whatever someone's doing. Their pointer goes
    /// straight through it too, so a stray scroll can't change what's being photographed.
    @MainActor
    private static func present(_ window: NSWindow) {
        window.ignoresMouseEvents = true
        window.orderFrontRegardless()
        window.makeKey()
    }

    @MainActor
    private static func capture(_ view: AnyView, size: NSSize, to output: URL) async throws {
        let window = ScenarioWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.contentView = NSHostingView(rootView: view)
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
        window.center()
        present(window)
        try await Task.sleep(for: .milliseconds(700))
        try await screenshot(window, to: output)
    }

    /// The controls over the kinds of backdrop that are hardest to read on, with no recording
    /// behind them. Writes the measured contrast next to the image.
    @MainActor
    private static func captureContrast(_ backdrop: String, to output: URL) async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "remind-contrast-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let core = try LiveCore(vaultDirectory: directory, masterKey: Data(repeating: 5, count: 32))

        let size = NSSize(width: 1512, height: 982)
        let window = ScenarioWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        let controller = TimelineController(core: core, display: UUID(), frame: NSRect(origin: .zero, size: size))
        let search = SearchModel(core: core, debounce: .milliseconds(1))
        controller.install(chrome: OverlayContent(
            core: core,
            timeline: controller,
            search: search,
            highlights: HighlightModel(),
            onOpen: {},
            onDismiss: {},
            actions: OverflowActions(),
            onSelectHit: { _, _ in },
            onOpenHit: { _ in },
            fieldCreated: { _ in },
            searchEditing: { _ in },
            searchCancelled: {},
            coachMarks: CoachMarkProgress(defaults: scenarioDefaults(coachMarksAt: 3))
        ))
        window.contentView = controller.rootView
        window.center()
        present(window)
        controller.present(at: Date().addingTimeInterval(-90), immediate: try backdropBuffer(backdrop, size: size))
        controller.model.isSearchVisible = false
        controller.model.showContext(FrameContext(bundleID: "com.apple.Safari", window: "Backdrop"))
        try await Task.sleep(for: .milliseconds(1000))
        controller.model.isEmpty = false
        try await Task.sleep(for: .milliseconds(200))
        try await screenshot(window, to: output)

        // Around the time pill: its text is the bright end, and its background the dark.
        guard let data = try? Data(contentsOf: output), let bitmap = NSBitmapImageRep(data: data) else { return }
        let scale = CGFloat(bitmap.pixelsWide) / size.width
        let pill = CGRect(x: size.width / 2 - 70, y: size.height - 80 - 30, width: 140, height: 24)
        var luminances: [Double] = []
        for y in stride(from: pill.minY * scale, to: pill.maxY * scale, by: 1) {
            for x in stride(from: pill.minX * scale, to: pill.maxX * scale, by: 1) {
                guard let color = bitmap.colorAt(x: Int(x), y: Int(y))?.usingColorSpace(.sRGB) else { continue }
                luminances.append(Contrast.luminance(
                    red: Double(color.redComponent),
                    green: Double(color.greenComponent),
                    blue: Double(color.blueComponent)
                ))
            }
        }
        luminances.sort()
        let dark = luminances[luminances.count / 5]
        let bright = luminances[luminances.count * 99 / 100]
        let ratio = Contrast.ratio(bright, dark)
        try String(format: "%@ %.2f:1 (text %.3f, behind it %.3f)\n", backdrop, ratio, bright, dark)
            .write(toFile: output.path + ".txt", atomically: true, encoding: .utf8)
    }

    /// One of the hard backdrops, as a frame.
    private static func backdropBuffer(_ kind: String, size: NSSize) throws -> CVPixelBuffer {
        let width = Int(size.width) * 2
        let height = Int(size.height) * 2
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(
            nil, width, height, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary,
            &buffer
        )
        guard let buffer else { throw ScenarioError.unknown("no buffer") }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let context = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer),
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        )!
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        switch kind {
        case "white":
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(bounds)
        case "black":
            context.setFillColor(CGColor(gray: 0, alpha: 1))
            context.fill(bounds)
        case "saturated":
            context.setFillColor(CGColor(srgbRed: 1, green: 0.1, blue: 0.3, alpha: 1))
            context.fill(bounds)
        default:
            // Dense black-on-white marks, which are the worst case for reading on top of.
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(bounds)
            context.setFillColor(CGColor(gray: 0, alpha: 1))
            var random = SystemRandomNumberGenerator()
            for y in stride(from: 0, to: height, by: 28) {
                var x = 0
                while x < width {
                    let word = Int.random(in: 16...90, using: &random)
                    context.fill(CGRect(x: x, y: y, width: word, height: 14))
                    x += word + 10
                }
            }
        }
        return buffer
    }

    /// Opens the real menu from the menu bar, as a click would, and photographs it from a
    /// task that runs while it tracks.
    @MainActor
    private static func captureStatusMenu(to output: URL) async throws {
        let controller = AppController()
        controller.debugPretendsSetUp = true
        let status = StatusMenu(controller: controller)
        var failure: (any Error)?
        var finished = false
        // A menu that won't close must not stay open on someone's screen. This starts before
        // the menu opens and runs off the main thread, which the menu's tracking loop can
        // hold on to, so nothing the menu does can stop it.
        let output = output
        DispatchQueue.global().asyncAfter(deadline: .now() + 6) { exit(0) }
        Task { @MainActor in
            defer {
                finished = true
                status.closeMenu()
            }
            try? await Task.sleep(for: .milliseconds(800))
            do {
                try await ScreenContent.saveScreenshotOfLargestOwnWindow(to: output)
            } catch {
                failure = error
            }
        }
        try await Task.sleep(for: .milliseconds(200))
        status.openMenu()
        while !finished {
            try await Task.sleep(for: .milliseconds(50))
        }
        withExtendedLifetime(status) {}
        if let failure { throw failure }
    }

    /// The timeline's … menu, opened as a click opens it, and photographed while it tracks.
    @MainActor
    private static func captureOverflowMenu(to output: URL) async throws {
        var actions = OverflowActions()
        actions.isCapturing = { true }
        actions.isListening = { false }
        let menu = OverflowMenu.makeMenu(actions: actions, confirmForget: {})
        var failure: (any Error)?
        var finished = false
        DispatchQueue.global().asyncAfter(deadline: .now() + 6) { exit(0) }
        Task { @MainActor in
            defer {
                finished = true
                menu.cancelTracking()
            }
            try? await Task.sleep(for: .milliseconds(800))
            do {
                try await ScreenContent.saveScreenshotOfLargestOwnWindow(to: output)
            } catch {
                failure = error
            }
        }
        try await Task.sleep(for: .milliseconds(100))
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
        while !finished {
            try await Task.sleep(for: .milliseconds(50))
        }
        if let failure { throw failure }
    }

    @MainActor
    private static func captureOverlay(_ name: String, to output: URL) async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "remind-scenario-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let size = NSSize(width: 1512, height: 982)
        let core = try LiveCore(vaultDirectory: directory, masterKey: Data(repeating: 9, count: 32))
        let display = UUID()
        let end = Date()
        let count = 120
        let recording = try await FixtureVault.record(
            into: core,
            width: Int(size.width) * 2,
            height: Int(size.height) * 2,
            count: count,
            display: display,
            start: end.addingTimeInterval(-Double(count) * 2),
            appForScene: { scene in
                switch scene {
                case "editor": "com.apple.dt.Xcode"
                case "article": "com.apple.Safari"
                case "terminal": "com.apple.Terminal"
                case "table": "com.apple.Notes"
                default: "com.apple.QuickTimePlayerX"
                }
            }
        )

        let window = ScenarioWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        let controller = TimelineController(core: core, display: display, frame: NSRect(origin: .zero, size: size))
        let search = SearchModel(core: core, debounce: .milliseconds(1))
        let highlights = HighlightModel()
        var textField: NSTextField?
        controller.install(chrome: OverlayContent(
            core: core,
            timeline: controller,
            search: search,
            highlights: highlights,
            onOpen: {},
            onDismiss: {},
            actions: OverflowActions(),
            onSelectHit: { _, _ in },
            onOpenHit: { _ in },
            fieldCreated: { textField = $0 },
            searchEditing: { _ in },
            searchCancelled: {},
            coachMarks: CoachMarkProgress(defaults: scenarioDefaults(coachMarksAt: name == "coach-marks" ? 0 : 3))
        ))
        window.contentView = controller.rootView
        window.center()
        present(window)
        controller.ignoreRealPointer()
        controller.present(at: recording.time(of: count - 12))
        // Opening by scrolling leaves the frame clear, which is what `timeline` shows.
        controller.model.isSearchVisible = name != "timeline"

        if name == "search-expanded" || name == "search-compact" {
            // OCR, so there's something to find.
            let worker = OCRWorker(core: core)
            worker.start()
            let began = Date()
            var trace = ""
            var lastProcessed = -1
            var wasWarming = true
            while worker.framesProcessed < count, Date().timeIntervalSince(began) < 900 {
                if worker.framesProcessed != lastProcessed || worker.isWarmingUp != wasWarming {
                    lastProcessed = worker.framesProcessed
                    wasWarming = worker.isWarmingUp
                    trace += String(format: "after %.1f s: processed %d, warming up: %@\n", Date().timeIntervalSince(began), lastProcessed, "\(wasWarming)")
                }
                try await Task.sleep(for: .milliseconds(100))
            }
            trace += String(format: "finished after %.1f s\n", Date().timeIntervalSince(began))
            try? trace.write(toFile: output.path + ".trace", atomically: true, encoding: .utf8)
            worker.stop()
            if name == "search-expanded", let word = recording.words[count - 12].filter({ $0.count >= 6 }).sorted().first {
                // Results commit in batches, so this waits until the word can be found.
                var log = "word \(word), processed \(worker.framesProcessed)\n"
                for attempt in 0..<100 {
                    let session = try core.search(word, facets: SearchFacets(), order: .relevance)
                    let hits = try session?.nextPage().hits.count ?? -1
                    if attempt % 20 == 0 || hits > 0 { log += "attempt \(attempt): \(hits) hits, stats \(core.stats())\n" }
                    if hits > 0 { break }
                    try await Task.sleep(for: .milliseconds(100))
                }
                try? log.write(toFile: output.path + ".log", atomically: true, encoding: .utf8)
                search.text = word
            }
        }
        if name == "jump-to-date" {
            controller.model.isJumpToDateOpen = true
        }
        if name == "timeline-zoom" {
            controller.model.isZoomOpen = true
        }
        if name == "forget-confirm" {
            controller.model.isConfirmingForget = true
        }
        if name == "search-apps" {
            search.loadApps()
            search.isAppsOpen = true
        }
        if name == "search-starred" {
            for frame in [8, 40, 75, 100] {
                if let found = try core.lookup(display: display, at: recording.time(of: frame)) {
                    try core.setStarred(true, frameID: found.id)
                }
            }
            search.starredOnly = true
        }
        if name.hasPrefix("slice-") {
            // Real events through the same path the mouse uses, once the strip has loaded.
            try await Task.sleep(for: .milliseconds(600))
            let middle = Double(size.width) / 2
            switch name {
            case "slice-hover":
                controller.simulateStrip(.moved(middle - 90))
            case "slice-selected", "slice-confirm":
                controller.simulateStrip(.down(middle - 90, clicks: 1))
                controller.simulateStrip(.up(middle - 90))
            default:
                controller.simulateStrip(.down(middle - 300, clicks: 1))
                controller.simulateStrip(.dragged(middle - 200))
                controller.simulateStrip(.dragged(middle + 60))
                controller.simulateStrip(.up(middle + 60))
            }
            try await Task.sleep(for: .milliseconds(300))
            if name == "slice-confirm" {
                controller.model.isConfirmingDelete = true
            }
        }
        _ = textField
        try await Task.sleep(for: .milliseconds(1200))
        try await screenshot(window, to: output)
    }

    /// The windows that show history, over a real vault with something in it.
    @MainActor
    private static func captureHistoryWindow(_ name: String, to output: URL) async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "remind-scenario-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let core = try LiveCore(vaultDirectory: directory, masterKey: Data(repeating: 9, count: 32))

        let end = Date()
        let start = end.addingTimeInterval(-3600)
        let count = name == "recap" ? 400 : 40
        let recording = try await FixtureVault.record(
            into: core,
            width: 1600,
            height: 1000,
            count: count,
            start: start,
            spacing: 3000 / Double(count),
            appForScene: { scene in
                switch scene {
                case "editor": "com.apple.dt.Xcode"
                case "article": "com.apple.Safari"
                case "terminal": "com.apple.Terminal"
                case "table": "com.apple.Notes"
                default: "com.apple.QuickTimePlayerX"
                }
            }
        )
        // Something said, so there's a meeting to find.
        let spoken = "We agreed the launch moves to March so the storage work can finish first. Sam will share the numbers on Friday, and the next review is on Tuesday."
            .split(separator: " ").map(String.init)
        let callStart = start.addingTimeInterval(600)
        let words = spoken.enumerated().map { index, word in
            SpokenWord(text: word, time: callStart.addingTimeInterval(Double(index) * 0.45), duration: 0.4, confidence: 0.96, isMe: index < 12)
        }
        try core.appendTranscript(words, title: "Design review")
        try core.recordMeeting(title: "Design review", from: callStart, to: callStart.addingTimeInterval(1500))

        let view: AnyView
        var size = NSSize(width: 560, height: 640)
        switch name {
        case "transcripts":
            try await waitForTranscript(core, from: start, to: end)
            view = AnyView(TranscriptsView(core: core, onOpen: { _ in }))
            size = NSSize(width: 480, height: 560)
        case "transcript":
            try await waitForTranscript(core, from: start, to: end)
            view = AnyView(TranscriptView(
                core: core,
                interval: DateInterval(start: callStart, duration: 1500),
                title: "Design review",
                onOpenMoment: { _ in }
            ))
        case "recap":
            try await waitForTranscript(core, from: start, to: end)
            view = AnyView(RecapView(core: core, onOpenMoment: { _ in }))
            size = NSSize(width: 620, height: 720)
        default:
            let worker = OCRWorker(core: core)
            worker.start()
            let began = Date()
            while worker.framesProcessed < count, Date().timeIntervalSince(began) < 300 {
                try await Task.sleep(for: .milliseconds(100))
            }
            try await Task.sleep(for: .milliseconds(800))
            worker.stop()
            let model = AskModel(engine: AskEngine(core: core, generator: ScenarioAnswers()))
            model.draft = "What did I do today?"
            model.send()
            view = AnyView(AskView(model: model, onOpenMoment: { _ in }))
            size = NSSize(width: 560, height: 680)
        }
        _ = recording
        let window = ScenarioWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = name.capitalized
        window.contentView = NSHostingView(rootView: view)
        window.center()
        present(window)
        try await Task.sleep(for: .milliseconds(1500))
        try await screenshot(window, to: output)
    }

    /// Words reach the index in batches.
    private static func waitForTranscript(_ core: any RemindCore, from: Date, to: Date) async throws {
        for _ in 0..<100 {
            if try !core.transcriptSessions(from: from, to: to, limit: 1).isEmpty { return }
            try await Task.sleep(for: .milliseconds(100))
        }
    }
}

/// A written answer, without depending on whether this Mac has Apple's model.
private struct ScenarioAnswers: AnswerGenerator {
    var unavailableReason: ModelUnavailable? { nil }
    var contextSize: Int { 4096 }
    func tokenCount(_ text: String) async -> Int { text.count / 4 }
    func answer(instructions: String, prompt: String) -> AsyncThrowingStream<String, any Error> {
        AsyncThrowingStream { continuation in
            continuation.yield("You spent most of the morning in your editor [1], then read through some notes [2] and finished in the terminal [3].")
            continuation.finish()
        }
    }
}

/// Defaults that don't touch the real app's, with the hints already at a given step.
@MainActor
private func scenarioDefaults(coachMarksAt step: Int) -> UserDefaults {
    let defaults = UserDefaults(suiteName: "remind-scenario")!
    defaults.set(step, forKey: "coachMarkStep")
    return defaults
}

/// Draws its controls in their active colours without activating the app, so taking a
/// screenshot doesn't take focus away from whatever someone's doing.
private final class ScenarioWindow: NSWindow {
    override var isKeyWindow: Bool { true }
    override var isMainWindow: Bool { true }
}

/// Settings with no real actions behind it.
@MainActor
private final class PreviewActions: SettingsActions {
    func storageUsage() async -> StorageUsage {
        StorageUsage(
            recordingBytes: 18_400_000_000,
            freeBytes: 92_000_000_000,
            oldest: Date().addingTimeInterval(-30 * 86_400),
            apps: [
                AppUsage(bundleID: "com.apple.Safari", bytes: 9_200_000_000, frames: 90_000),
                AppUsage(bundleID: "com.apple.dt.Xcode", bytes: 6_100_000_000, frames: 60_000),
                AppUsage(bundleID: "com.apple.Terminal", bytes: 2_400_000_000, frames: 30_000),
                AppUsage(bundleID: "com.apple.Notes", bytes: 700_000_000, frames: 9_000),
            ]
        )
    }
    func deleteAllData() async throws {}
    func deleteRange(_ interval: DateInterval) async throws {}
    func deleteRecordings(ofApp bundleID: String) async throws {}
    func applyRetention(_ period: RetentionPeriod) async throws {}
    var loginItemNeedsApproval: Bool { false }
    func openLoginItemSettings() {}
    var updatesAvailable: Bool { false }
    func saveRecoveryKey() {}
    func revealVault() {}
    func setLaunchAtLogin(_ enabled: Bool) {}
    func setChecksForUpdates(_ enabled: Bool) {}
    func setShowInDock(_ show: Bool) {}
    func setNamesMeetingsFromCalendar(_ enabled: Bool) {}
    var launchAtLogin: Bool { true }
    var runningApps: [AppChoice] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { app in
                guard let id = app.bundleIdentifier, let url = app.bundleURL else { return nil }
                return AppChoice(bundleID: id, name: app.localizedName ?? id, path: url.path)
            }
    }
}

#endif
