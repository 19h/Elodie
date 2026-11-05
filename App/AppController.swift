import AppKit
import Audio
import Capture
import CoreAPI
import CoreLive
import CoreVideo
import FeatureAsk
import FeatureMeetings
import FeatureOnboarding
import FeatureRecap
import FeatureSettings
import Ingest
import KeyboardShortcuts
import ServiceManagement
import SwiftUI

extension KeyboardShortcuts.Name {
    static let search = Self("search", default: .init(.space, modifiers: [.command, .shift]))
    static let ask = Self("ask", default: .init(.minus, modifiers: [.command, .shift]))
    static let dailyRecap = Self("dailyRecap")
    // ⇧⌘S is Save As in most apps, so stars have no global shortcut until one is
    // chosen. It works inside the overlay.
    static let starMoment = Self("starMoment")
    static let toggleAudio = Self("toggleAudio")
}

/// Why Remind can't record, as shown to the user.
enum RecordingProblem: Equatable {
    case permissionMissing
    case keyMissing
    case keychainLocked
    case diskFull
    case other(String)

    var message: String {
        switch self {
        case .permissionMissing: "Remind needs Screen Recording permission."
        case .keyMissing: "The key for your recordings is missing from your keychain."
        case .keychainLocked: "Your keychain is locked, so recordings can't be opened yet."
        case .diskFull: "Recording stopped because the disk is nearly full."
        case .other(let text): text
        }
    }
}

/// Starts everything, and owns the app's top-level state.
@MainActor
final class AppController: NSObject {
    /// Below this, background OCR catch-up pauses.
    static let lowDiskBytes: Int64 = 10_000_000_000
    /// Below this, recording stops.
    static let criticalDiskBytes: Int64 = 2_000_000_000

    let settings = SettingsModel()
    private let permissions = PermissionMonitor()
    private var core: LiveCore?
    private var recording: RecordingController?
    private var ocr: OCRWorker?
    private var overlay: OverlayCoordinator?
    private var menu: StatusMenu?
    private var onboardingWindow: NSWindow?
    private var settingsWindow: NSWindow?
    private var askWindow: NSWindow?
    private var recapWindow: NSWindow?
    private var transcriptWindow: NSWindow?
    private var promptPanel: NSPanel?
    private var audio: AudioRecorder?
    private var meetingTimer: Timer?
    private var currentMeeting: DetectedMeeting?
    private var dismissedMeeting: DetectedMeeting?
    private var audioStarted: Date?
    private var lastTranscript: DateInterval?
    private var meetingGoneSince: Date?
    private let inventory = WindowInventory()
    let updater = Updater()
    private(set) var isTranscribing = false
    /// Set once the app is running, so Shortcuts actions and the Control Center button can
    /// reach it.
    private(set) static weak var shared: AppController?
    private var scrollMonitor: ScrollToOpen?
    private var resumeTimer: Timer?
    private var diskTimer: Timer?
    private(set) var problem: RecordingProblem?
    private(set) var isPaused = false

    private var vaultDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appending(path: Bundle.main.bundleIdentifier ?? "app.remind.Remind", directoryHint: .isDirectory)
            .appending(path: "vault", directoryHint: .isDirectory)
    }

    func start() {
        Self.shared = self
        updater.checksAutomatically = settings.checkForUpdates
        listenForControlCenter()
        NSApp.setActivationPolicy(settings.showInDock ? .regular : .accessory)
        menu = StatusMenu(controller: self)
        registerShortcuts()

        if settings.hasFinishedOnboarding, permissions.allRequiredGranted {
            openVaultAndRecord()
        } else {
            showOnboarding()
        }
    }

    func prepareToQuit() {
        try? core?.sealAll()
    }

    private func registerShortcuts() {
        KeyboardShortcuts.onKeyDown(for: .search) { [weak self] in self?.showSearch() }
        KeyboardShortcuts.onKeyDown(for: .ask) { [weak self] in self?.openAsk() }
        KeyboardShortcuts.onKeyDown(for: .dailyRecap) { [weak self] in self?.openRecap() }
        KeyboardShortcuts.onKeyDown(for: .starMoment) { [weak self] in self?.starMoment() }
        KeyboardShortcuts.onKeyDown(for: .toggleAudio) { [weak self] in self?.toggleTranscribing() }
        scrollMonitor = ScrollToOpen { [weak self] in self?.overlay?.open() }
    }

    // MARK: Opening the vault

    private func openVaultAndRecord() {
        do {
            let directory = vaultDirectory
            let exists = FileManager.default.fileExists(atPath: directory.appending(path: "vault.db").path)
            let key = try KeyStore.key(vaultExists: exists)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            excludeFromBackups(directory)
            Task.detached(priority: .userInitiated) { [weak self] in
                // Recovery can take a moment, so this stays off the main thread.
                do {
                    let core = try LiveCore(vaultDirectory: directory, masterKey: key)
                    await self?.didOpen(core)
                } catch {
                    await self?.show(problem: .other("Your recordings couldn't be opened: \(error)"))
                }
            }
        } catch let failure as KeyStore.Failure {
            switch failure {
            case .keyMissing: show(problem: .keyMissing)
            case .keychainUnavailable: show(problem: .keychainLocked)
            case .couldNotCreate(let status): show(problem: .other("Couldn't create a key (\(status))."))
            }
        } catch {
            show(problem: .other("Your recordings couldn't be opened: \(error)"))
        }
    }

    /// Recordings are encrypted with a key that doesn't leave this Mac, so a backup of
    /// them could never be read on a restored machine without the recovery key.
    private func excludeFromBackups(_ directory: URL) {
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var url = directory
        try? url.setResourceValues(values)
    }

    private func didOpen(_ core: LiveCore) {
        self.core = core
        problem = nil
        let overlay = OverlayCoordinator(core: core)
        self.overlay = overlay

        let worker = OCRWorker(core: core)
        worker.start()
        ocr = worker

        let recording = RecordingController(core: core, policy: currentPolicy())
        recording.onStateChange = { [weak self] state in
            DispatchQueue.main.async { self?.recordingChanged(state) }
        }
        self.recording = recording
        overlay.latestFrame = { [weak recording] in recording?.latestFrame }
        overlay.excludeApp = { [weak self] bundleID in
            self?.settings.excludedApps.insert(bundleID)
            self?.recording?.update(policy: self?.currentPolicy() ?? ExclusionPolicy(excludedBundleIDs: []))
        }
        audio = AudioRecorder(core: core)
        observeSystemEvents()
        startRecording()
        applyRetention()
        startDiskWatch()
        startMeetingWatch()
        menu?.refresh()
    }

    // MARK: Transcribing

    func toggleTranscribing() {
        if isTranscribing {
            stopTranscribing()
        } else {
            startTranscribing(title: currentMeeting?.title ?? currentMeeting?.app)
        }
    }

    private func startTranscribing(title: String?) {
        guard !isTranscribing, let audio else { return }
        isTranscribing = true
        audioStarted = Date()
        menu?.refresh()
        let sources = AudioSources(
            microphone: settings.audioSource != .speakerOnly,
            speakers: settings.audioSource != .microphoneOnly
        )
        let locale = Locale(identifier: settings.transcriptionLanguage)
        Task {
            do {
                try await audio.start(sources: sources, locale: locale, title: title)
            } catch {
                isTranscribing = false
                show(problem: .other("Transcription couldn't start: \(error.localizedDescription)"))
            }
        }
    }

    private func stopTranscribing() {
        guard isTranscribing else { return }
        isTranscribing = false
        if let audioStarted {
            lastTranscript = DateInterval(start: audioStarted, end: Date())
        }
        menu?.refresh()
        Task { await audio?.stop() }
    }

    var hasTranscript: Bool { lastTranscript != nil }

    func openLastTranscript() {
        guard let core, let lastTranscript else { return }
        let view = TranscriptView(
            core: core,
            interval: lastTranscript,
            title: currentMeeting?.app
        ) { [weak self] time in
            self?.overlay?.open(at: time)
        }
        transcriptWindow = makeWindow(title: "Transcript", content: view, size: NSSize(width: 560, height: 640))
        show(transcriptWindow)
    }

    // MARK: Meetings

    private func startMeetingWatch() {
        meetingTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkForMeeting() }
        }
    }

    private func checkForMeeting() {
        let windows = inventory.onScreenWindows().filter { $0.layer == 0 }.map { window in
            MeetingSignals.Window(bundleID: inventory.identify(window.ownerPID).bundleID, title: window.title)
        }
        let detected = MeetingDetector.detect(MeetingSignals(
            windows: windows,
            isMicrophoneInUse: MeetingDetector.isMicrophoneInUse
        ))

        if let detected {
            meetingGoneSince = nil
            guard detected != currentMeeting else { return }
            currentMeeting = detected
            guard !isTranscribing, detected != dismissedMeeting else { return }
            switch settings.meetingDetected {
            case .ask: showMeetingPrompt(detected)
            case .recordAutomatically: startTranscribing(title: detected.title ?? detected.app)
            case .doNotRecord: break
            }
        } else if currentMeeting != nil {
            // Windows change as calls settle, so this waits before calling it over.
            let gone = meetingGoneSince ?? Date()
            meetingGoneSince = gone
            if Date().timeIntervalSince(gone) > 30 {
                currentMeeting = nil
                dismissedMeeting = nil
                meetingGoneSince = nil
                closeMeetingPrompt()
                stopTranscribing()
            }
        }
    }

    private func showMeetingPrompt(_ meeting: DetectedMeeting) {
        closeMeetingPrompt()
        let view = MeetingPrompt(
            appName: meeting.app,
            title: meeting.title,
            onRecord: { [weak self] in
                self?.closeMeetingPrompt()
                self?.startTranscribing(title: meeting.title ?? meeting.app)
            },
            onDismiss: { [weak self] in
                self?.dismissedMeeting = meeting
                self?.closeMeetingPrompt()
            }
        )
        let hosting = NSHostingView(rootView: view)
        let size = hosting.fittingSize
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = hosting
        panel.isReleasedWhenClosed = false
        if let screen = NSScreen.main {
            panel.setFrameOrigin(NSPoint(
                x: screen.visibleFrame.maxX - size.width - 16,
                y: screen.visibleFrame.maxY - size.height - 16
            ))
        }
        panel.orderFrontRegardless()
        promptPanel = panel
    }

    private func closeMeetingPrompt() {
        promptPanel?.close()
        promptPanel = nil
    }

    // MARK: Control Center

    /// The Control Center button runs in a separate sandboxed process, and it signals
    /// through this notification, which can't carry any data.
    private func listenForControlCenter() {
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            Unmanaged.passUnretained(self).toOpaque(),
            { _, _, _, _, _ in
                DispatchQueue.main.async {
                    AppController.shared?.togglePaused()
                }
            },
            "app.remind.toggle-recording" as CFString,
            nil,
            .deliverImmediately
        )
    }

    func togglePaused() {
        setPaused(!isPaused)
    }

    /// Opens the timeline at a moment, from a link or a Shortcuts action.
    func showMoment(at time: Date) {
        overlay?.open(at: time)
    }

    /// Permanently deletes the last 5 minutes.
    func forgetRecent() {
        guard let core else { return }
        let now = Date()
        Task.detached(priority: .userInitiated) {
            try? core.deleteRange(from: now.addingTimeInterval(-5 * 60), to: now)
        }
    }

    private func currentPolicy() -> ExclusionPolicy {
        ExclusionPolicy(
            excludedBundleIDs: settings.excludedApps,
            excludesPrivateWindows: settings.excludePrivateWindows
        )
    }

    // MARK: Recording

    private func startRecording() {
        guard let recording, !isPaused else { return }
        recording.update(policy: currentPolicy())
        Task {
            do {
                try await recording.start()
            } catch {
                show(problem: .other("Recording couldn't start: \(error.localizedDescription)"))
            }
        }
    }

    private func recordingChanged(_ state: RecordingState) {
        switch state {
        case .recording:
            problem = nil
        case .interrupted(let reason):
            switch reason {
            case .permissionMissing, .stoppedBySystem:
                show(problem: .permissionMissing)
            case .stoppedByUser:
                setPaused(true)
            case .displayGone:
                startRecording()
            case .other(let code):
                show(problem: .other("Recording stopped unexpectedly (\(code))."))
            }
        case .stopped:
            break
        }
        menu?.refresh()
    }

    private func show(problem: RecordingProblem) {
        self.problem = problem
        menu?.refresh()
    }

    func setPaused(_ paused: Bool, for duration: TimeInterval? = nil) {
        isPaused = paused
        resumeTimer?.invalidate()
        resumeTimer = nil
        if paused {
            Task { await recording?.stop() }
            if let duration {
                resumeTimer = Timer.scheduledTimer(withTimeInterval: duration, repeats: false) { [weak self] _ in
                    MainActor.assumeIsolated { self?.setPaused(false) }
                }
            }
        } else {
            startRecording()
        }
        menu?.refresh()
    }

    private var observers: [Any] = []

    private func observeSystemEvents() {
        let workspace = NSWorkspace.shared.notificationCenter
        observers.append(workspace.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.systemWillSleep() }
        })
        observers.append(workspace.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.systemDidWake() }
        })
        let distributed = DistributedNotificationCenter.default()
        observers.append(distributed.addObserver(forName: Notification.Name("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.systemWillSleep() }
        })
        observers.append(distributed.addObserver(forName: Notification.Name("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.systemDidWake() }
        })
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.startRecording() }
        })
    }

    private func systemWillSleep() {
        // Everything recorded so far reaches the drive before the machine sleeps.
        Task {
            await recording?.stop()
            try? core?.sealAll()
        }
    }

    private func systemDidWake() {
        startRecording()
    }

    private func startDiskWatch() {
        diskTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkDisk() }
        }
        checkDisk()
    }

    private func checkDisk() {
        let free = (try? vaultDirectory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage ?? Int64.max
        if free < Self.criticalDiskBytes {
            if problem != .diskFull {
                Task {
                    await recording?.stop()
                    try? core?.sealAll()
                }
                show(problem: .diskFull)
            }
        } else if problem == .diskFull, free > Self.criticalDiskBytes * 2 {
            problem = nil
            startRecording()
            menu?.refresh()
        }
    }

    // MARK: Commands

    func showSearch() {
        overlay?.open(focusSearch: true)
    }

    func starMoment() {
        recording?.keepNextFrame()
    }

    func openAsk() {
        guard let core else { return }
        if askWindow == nil {
            let model = AskModel(engine: AskEngine(core: core))
            let view = AskView(model: model) { [weak self] hit in
                self?.overlay?.open(at: hit.capturedAt)
            }
            askWindow = makeWindow(title: "Ask Remind", content: view, size: NSSize(width: 560, height: 680))
        }
        show(askWindow)
    }

    func openRecap() {
        guard let core else { return }
        if recapWindow == nil {
            let view = RecapView(core: core) { [weak self] time in
                self?.overlay?.open(at: time)
            }
            recapWindow = makeWindow(title: "Daily Recap", content: view, size: NSSize(width: 620, height: 720))
        }
        show(recapWindow)
    }

    private func makeWindow<Content: View>(title: String.LocalizationValue, content: Content, size: NSSize) -> NSWindow {
        let window = NSWindow(contentViewController: NSHostingController(rootView: content))
        window.title = String(localized: title)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(size)
        window.isReleasedWhenClosed = false
        window.center()
        return window
    }

    private func show(_ window: NSWindow?) {
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    func openSettings() {
        if settingsWindow == nil {
            let hosting = NSHostingController(rootView: SettingsView(
                model: settings,
                actions: self,
                shortcuts: AnyView(ShortcutsTab())
            ))
            let window = NSWindow(contentViewController: hosting)
            window.title = String(localized: "Settings")
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.isReleasedWhenClosed = false
            settingsWindow = window
        }
        NSApp.activate()
        settingsWindow?.center()
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    private func showOnboarding() {
        let step = OnboardingStep(rawValue: UserDefaults.standard.string(forKey: "onboardingStep") ?? "") ?? .welcome
        let view = OnboardingView(
            permissions: permissions,
            step: step,
            appIcon: NSApp.applicationIconImage,
            onStepChange: { UserDefaults.standard.set($0.rawValue, forKey: "onboardingStep") },
            onRelaunch: { [weak self] in self?.relaunch() },
            onFinish: { [weak self] in self?.finishOnboarding() }
        )
        let window = NSWindow(contentViewController: NSHostingController(rootView: view))
        window.styleMask = [.titled, .closable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.center()
        onboardingWindow = window
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    /// macOS only applies a new Screen Recording grant to new processes.
    private func relaunch() {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }

    private func finishOnboarding() {
        settings.hasFinishedOnboarding = true
        UserDefaults.standard.removeObject(forKey: "onboardingStep")
        onboardingWindow?.close()
        onboardingWindow = nil
        openVaultAndRecord()
    }

    private func applyRetention() {
        let period = settings.retention
        Task { await applyRetention(period) }
    }
}

// MARK: Settings

extension AppController: SettingsActions {
    func storageUsage() async -> StorageUsage {
        let directory = vaultDirectory
        return await Task.detached(priority: .utility) {
            let free = (try? directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
                .volumeAvailableCapacityForImportantUsage ?? 0
            let attributes = try? FileManager.default.attributesOfItem(atPath: directory.path)
            return StorageUsage(
                recordingBytes: Self.allocatedSize(of: directory),
                freeBytes: free,
                oldest: attributes?[.creationDate] as? Date
            )
        }.value
    }

    private nonisolated static func allocatedSize(of directory: URL) -> Int64 {
        let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .isRegularFileKey]
        guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: Array(keys)) else {
            return 0
        }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: keys)
            if values?.isRegularFile == true {
                total += Int64(values?.totalFileAllocatedSize ?? 0)
            }
        }
        return total
    }

    func deleteAllData() async {
        guard let core else { return }
        await Task.detached { try? core.deleteRange(from: .distantPast, to: .distantFuture) }.value
    }

    func deleteRange(_ interval: DateInterval) async {
        guard let core else { return }
        await Task.detached { try? core.deleteRange(from: interval.start, to: interval.end) }.value
    }

    func applyRetention(_ period: RetentionPeriod) async {
        guard let core, let cutoff = period.cutoff(now: Date()) else { return }
        await Task.detached { try? core.deleteRange(from: .distantPast, to: cutoff) }.value
    }

    func saveRecoveryKey() {
        guard let key = try? KeyStore.key(vaultExists: true) else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Remind recovery key.txt"
        panel.message = "Keep this somewhere safe. Anyone with this key and your files can read your recordings."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let text = """
        Remind recovery key

        \(KeyStore.recoveryText(for: key))

        This decrypts your recordings. Keep it somewhere safe and private.
        """
        try? text.write(to: url, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    func revealVault() {
        NSWorkspace.shared.activateFileViewerSelecting([vaultDirectory])
    }

    var launchAtLogin: Bool {
        SMAppService.mainApp.status == .enabled
    }

    func setChecksForUpdates(_ enabled: Bool) {
        settings.checkForUpdates = enabled
        updater.checksAutomatically = enabled
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        if enabled {
            try? SMAppService.mainApp.register()
        } else {
            try? SMAppService.mainApp.unregister()
        }
    }

    var runningApps: [AppChoice] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { app in
                guard let id = app.bundleIdentifier, let url = app.bundleURL else { return nil }
                return AppChoice(bundleID: id, name: app.localizedName ?? id, path: url.path)
            }
    }
}

struct ShortcutsTab: View {
    var body: some View {
        Form {
            KeyboardShortcuts.Recorder("Search Remind:", name: .search)
            KeyboardShortcuts.Recorder("Ask Remind:", name: .ask)
            KeyboardShortcuts.Recorder("Daily Recap:", name: .dailyRecap)
            KeyboardShortcuts.Recorder("Star moment:", name: .starMoment)
            KeyboardShortcuts.Recorder("Audio capture:", name: .toggleAudio)
            LabeledContent("") {
                Text("⌘⇧ and scroll also opens Remind from anywhere.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.columns)
        .padding(28)
    }
}
