#if DEBUG
import AppKit
import Capture
import CoreAPI
import CoreFake
import CoreLive
import FeatureOnboarding
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
        case "timeline", "search-compact", "search-expanded", "jump-to-date", "coach-marks":
            try await captureOverlay(name, to: output)
        case "overlay-input":
            try await InputSelfTest.run(to: output)
        case "status-menu":
            try await captureStatusMenu(to: output)
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

    /// Shows a window without taking focus from whatever someone's doing.
    @MainActor
    private static func present(_ window: NSWindow) {
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

    /// Opens the real menu from the menu bar, as a click would, and photographs it from a
    /// task that runs while it tracks.
    @MainActor
    private static func captureStatusMenu(to output: URL) async throws {
        let controller = AppController()
        let status = StatusMenu(controller: controller)
        var failure: (any Error)?
        var finished = false
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
        _ = textField
        try await Task.sleep(for: .milliseconds(1200))
        try await screenshot(window, to: output)
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
        StorageUsage(recordingBytes: 18_400_000_000, freeBytes: 92_000_000_000, oldest: Date().addingTimeInterval(-30 * 86_400))
    }
    func deleteAllData() async {}
    func deleteRange(_ interval: DateInterval) async {}
    func applyRetention(_ period: RetentionPeriod) async {}
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
