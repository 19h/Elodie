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
        case "settings-screen", "settings-storage":
            let view = SettingsPreview(tab: name == "settings-screen" ? 1 : 4)
            try await capture(AnyView(view), size: NSSize(width: 640, height: 620), to: output)
        case "timeline", "search-compact", "search-expanded", "jump-to-date":
            try await captureOverlay(name, to: output)
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
            onFinish: {}
        ))
    }

    enum ScenarioError: Error {
        case unknown(String)
    }

    /// Screenshots a window through ScreenCaptureKit, so glass renders as it really does.
    @MainActor
    private static func capture(_ view: AnyView, size: NSSize, to output: URL) async throws {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.contentView = NSHostingView(rootView: view)
        window.center()
        window.orderFrontRegardless()
        try await Task.sleep(for: .milliseconds(700))
        try await ScreenContent.saveScreenshot(ofWindow: CGWindowID(window.windowNumber), to: output)
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
            start: end.addingTimeInterval(-Double(count) * 2)
        )

        let window = NSWindow(
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
            onSelectHit: { _ in },
            onOpenHit: { _ in },
            fieldCreated: { textField = $0 },
            searchEditing: { _ in },
            searchCancelled: {}
        ))
        window.contentView = controller.rootView
        window.center()
        window.orderFrontRegardless()
        controller.present(at: recording.time(of: count - 12))

        if name == "search-expanded" || name == "search-compact" {
            // OCR, so there's something to find.
            let worker = OCRWorker(core: core)
            worker.start()
            for _ in 0..<300 where worker.framesProcessed < count {
                try await Task.sleep(for: .milliseconds(100))
            }
            worker.stop()
            if name == "search-expanded", let word = recording.words[count - 12].filter({ $0.count >= 6 }).sorted().first {
                search.text = word
            }
        }
        if name == "jump-to-date" {
            controller.model.isJumpToDateOpen = true
        }
        _ = textField
        try await Task.sleep(for: .milliseconds(1200))
        try await ScreenContent.saveScreenshot(ofWindow: CGWindowID(window.windowNumber), to: output)
    }
}

/// Settings with no real actions behind it, opened on one tab.
private struct SettingsPreview: View {
    let tab: Int

    var body: some View {
        SettingsView(
            model: SettingsModel(defaults: UserDefaults(suiteName: "remind-scenario")!),
            actions: PreviewActions(),
            shortcuts: AnyView(ShortcutsTab())
        )
    }
}

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
