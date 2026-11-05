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
    case encoderFailed
    case keptCrashing
    case other(String)

    var message: String {
        switch self {
        case .permissionMissing: "Remind needs Screen Recording permission."
        case .keyMissing: "The key for your recordings is missing from your keychain."
        case .keychainLocked: "Your keychain is locked, so recordings can't be opened yet."
        case .diskFull: "Recording stopped because the disk is nearly full."
        case .encoderFailed: "Recording stopped because video encoding kept failing."
        case .keptCrashing: "Recording is paused because Remind kept crashing."
        case .other(let text): text
        }
    }

    /// Whether trying again might help. A missing key or a full disk needs something else
    /// to change first.
    var canRetry: Bool {
        switch self {
        case .permissionMissing, .encoderFailed, .keptCrashing, .other: true
        case .keyMissing, .keychainLocked, .diskFull: false
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
    private let calendar = MeetingCalendar()
    private var transcriptTitle: String?
    let updater = Updater()
    private(set) var isTranscribing = false
    /// Set once the app is running, so Shortcuts actions and the Control Center button can
    /// reach it.
    private(set) static weak var shared: AppController?
    private var scrollMonitor: ScrollToOpen?
    private var resumeTimer: Timer?
    private var maintenanceTimer: Timer?
    private var pausedReminder: Timer?
    private var lastRetention = Date()
    private let launchedAt = Date()
    private let crashGuard = CrashGuard()
    private static let loginAgent = SMAppService.agent(plistName: "app.remind.Remind.agent.plist")
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
        if crashGuard.launchShouldStayPaused() {
            isPaused = true
            problem = .keptCrashing
        }
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
        crashGuard.markCleanExit()
    }

    private func registerShortcuts() {
        KeyboardShortcuts.onKeyDown(for: .search) { [weak self] in self?.showSearch() }
        KeyboardShortcuts.onKeyDown(for: .ask) { [weak self] in self?.openAsk() }
        KeyboardShortcuts.onKeyDown(for: .dailyRecap) { [weak self] in self?.openRecap() }
        KeyboardShortcuts.onKeyDown(for: .starMoment) { [weak self] in self?.starMoment() }
        KeyboardShortcuts.onKeyDown(for: .toggleAudio) { [weak self] in self?.toggleTranscribing() }
        scrollMonitor = ScrollToOpen { [weak self] event in self?.overlay?.handleScroll(event) }
        scrollMonitor?.start()
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
        overlay.onOpenChange = { [weak self] isOpen in self?.scrollMonitor?.isOverlayOpen = isOpen }
        self.overlay = overlay

        let worker = OCRWorker(core: core)
        worker.usesAdditionalLanguages = settings.textRecognition == .additionalLanguages
        worker.start()
        ocr = worker

        let recording = RecordingController(core: core, policy: currentPolicy())
        recording.onStateChange = { [weak self] state in
            DispatchQueue.main.async { self?.recordingChanged(state) }
        }
        self.recording = recording
        overlay.latestFrame = { [weak recording] display in
            // A frame from another display would be the wrong picture, however recent.
            guard case .recording(display)? = recording?.currentState else { return nil }
            return recording?.latestFrame
        }
        overlay.excludeApp = { [weak self] bundleID in
            self?.settings.excludedApps.insert(bundleID)
            self?.recording?.update(policy: self?.currentPolicy() ?? ExclusionPolicy(excludedBundleIDs: []))
        }
        audio = AudioRecorder(core: core)
        observeSystemEvents()
        observeSettings()
        startRecording()
        applyRetention()
        startMaintenance()
        startMeetingWatch()
        menu?.refresh()
    }

    /// Keeps the recorder in step with Settings. What's excluded matters most: leaving an
    /// app out of recording has to take effect at once, not on the next launch.
    private func observeSettings() {
        withObservationTracking {
            _ = settings.excludedApps
            _ = settings.excludePrivateWindows
            _ = settings.textRecognition
        } onChange: { [weak self] in
            // This fires just before the change lands.
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.recording?.update(policy: self.currentPolicy())
                    self.ocr?.usesAdditionalLanguages = self.settings.textRecognition == .additionalLanguages
                    self.observeSettings()
                }
            }
        }
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
        transcriptTitle = title
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
            let interval = DateInterval(start: audioStarted, end: Date())
            lastTranscript = interval
            let title = transcriptTitle
            Task.detached(priority: .utility) { [core] in
                try? core?.recordMeeting(title: title, from: interval.start, to: interval.end)
            }
        }
        menu?.refresh()
        Task { await audio?.stop() }
    }

    var hasTranscript: Bool { lastTranscript != nil }

    var currentMeetingName: String? { currentMeeting?.app }

    func openLastTranscript() {
        guard let core, let lastTranscript else { return }
        let view = TranscriptView(
            core: core,
            interval: lastTranscript,
            title: transcriptTitle ?? currentMeeting?.app
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
        var detected = MeetingDetector.detect(MeetingSignals(
            windows: windows,
            isMicrophoneInUse: MeetingDetector.isMicrophoneInUse
        ))
        // The calendar often knows what a call is about when its window doesn't. This keeps
        // the name it first found, so a meeting doesn't count as new when an event ends.
        if let meeting = detected, meeting.title == nil {
            detected?.title = meeting.app == currentMeeting?.app
                ? currentMeeting?.title
                : (settings.namesMeetingsFromCalendar ? calendar.currentEventTitle() : nil)
        }

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
        showCard(view)
    }

    /// Shows a small card near the menu bar, without taking focus.
    private func showCard<Content: View>(_ view: Content) {
        closeMeetingPrompt()
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
        guard let recording, !isPaused, problem != .diskFull else { return }
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
            case .encoderFailed:
                show(problem: .encoderFailed)
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

    /// Starts again after a problem, once someone has dealt with its cause.
    func tryAgain() {
        problem = nil
        if core == nil {
            openVaultAndRecord()
        } else {
            setPaused(false)
        }
        menu?.refresh()
    }

    func setPaused(_ paused: Bool, for duration: TimeInterval? = nil) {
        isPaused = paused
        resumeTimer?.invalidate()
        resumeTimer = nil
        pausedReminder?.invalidate()
        pausedReminder = nil
        if paused {
            Task { await recording?.stop() }
            if let duration {
                resumeTimer = Timer.scheduledTimer(withTimeInterval: duration, repeats: false) { [weak self] _ in
                    MainActor.assumeIsolated { self?.setPaused(false) }
                }
            } else {
                // Open-ended pauses are easy to forget, and the cost is a gap in your history.
                pausedReminder = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated { self?.remindPaused() }
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

    private func remindPaused() {
        guard settings.remindWhenPaused else { return }
        showCard(NoticeCard(
            symbol: "pause.circle",
            title: "Remind is still paused",
            detail: "Nothing on your screen is being recorded.",
            primary: "Resume recording",
            secondary: "Keep paused",
            onPrimary: { [weak self] in
                self?.closeMeetingPrompt()
                self?.setPaused(false)
            },
            onSecondary: { [weak self] in self?.closeMeetingPrompt() }
        ))
    }

    /// Asks once, a week in, by which time there's history worth protecting.
    private func remindAboutRecoveryKey(now: Date = Date()) {
        let defaults = UserDefaults.standard
        guard let firstRun = defaults.object(forKey: "firstRunDate") as? Date else {
            defaults.set(now, forKey: "firstRunDate")
            return
        }
        guard now.timeIntervalSince(firstRun) > 7 * 86_400,
              !defaults.bool(forKey: "recoveryKeySaved"),
              !defaults.bool(forKey: "recoveryKeyReminderShown"),
              promptPanel == nil
        else { return }
        defaults.set(true, forKey: "recoveryKeyReminderShown")
        showCard(NoticeCard(
            symbol: "key",
            title: "Save your recovery key",
            detail: "If the key in your keychain is ever lost, this is the only way to read your recordings.",
            primary: "Save recovery key…",
            secondary: "Not now",
            onPrimary: { [weak self] in
                self?.closeMeetingPrompt()
                self?.saveRecoveryKey()
            },
            onSecondary: { [weak self] in self?.closeMeetingPrompt() }
        ))
    }

    private func startMaintenance() {
        maintenanceTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.maintain() }
        }
        maintain()
    }

    /// Everything that needs checking now and then.
    private func maintain(now: Date = Date()) {
        // Taking over scrolling needs Accessibility, which may have been allowed since launch.
        scrollMonitor?.start()
        checkDisk()
        updatePrivacyWarning()
        remindAboutRecoveryKey(now: now)
        // Without this, an app left running for months would keep expired recordings.
        if now.timeIntervalSince(lastRetention) > 3600 {
            lastRetention = now
            applyRetention()
        }
        if now.timeIntervalSince(launchedAt) > 600 {
            crashGuard.markStable()
        }
    }

    private func updatePrivacyWarning() {
        switch recording?.privacyCheckTrouble {
        case .accessibilityOff:
            settings.privateBrowsingWarning = String(
                localized: "Accessibility is off for Remind, so it can only spot private windows by their titles."
            )
        case .browserNotResponding(let bundleID):
            let name = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)?
                .deletingPathExtension().lastPathComponent ?? bundleID
            settings.privateBrowsingWarning = String(
                localized: "\(name) isn't responding to Remind, so its windows aren't being recorded right now."
            )
        case nil:
            settings.privateBrowsingWarning = nil
        }
    }

    private func checkDisk() {
        let free = (try? vaultDirectory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage ?? Int64.max
        ocr?.allowsBackfill = free >= Self.lowDiskBytes
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
            settingsWindow = SettingsWindow.make(
                model: settings,
                actions: self,
                shortcuts: AnyView(ShortcutsTab())
            )
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
            onFinish: { [weak self] openAtLogin in self?.finishOnboarding(openAtLogin: openAtLogin) }
        )
        let window = NSWindow(contentViewController: NSHostingController(rootView: view))
        window.styleMask = [.titled, .closable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
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

    private func finishOnboarding(openAtLogin: Bool) {
        if openAtLogin {
            setLaunchAtLogin(true)
        }
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
        guard (try? text.write(to: url, atomically: true, encoding: .utf8)) != nil else { return }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        UserDefaults.standard.set(true, forKey: "recoveryKeySaved")
    }

    func revealVault() {
        NSWorkspace.shared.activateFileViewerSelecting([vaultDirectory])
    }

    var launchAtLogin: Bool {
        Self.loginAgent.status == .enabled
    }

    func setNamesMeetingsFromCalendar(_ enabled: Bool) {
        guard enabled else {
            settings.namesMeetingsFromCalendar = false
            return
        }
        // Asking happens now, when it's clear why, and not in the middle of a meeting.
        Task {
            settings.namesMeetingsFromCalendar = await calendar.requestAccess()
        }
    }

    func setShowInDock(_ show: Bool) {
        settings.showInDock = show
        NSApp.setActivationPolicy(show ? .regular : .accessory)
    }

    func setChecksForUpdates(_ enabled: Bool) {
        settings.checkForUpdates = enabled
        updater.checksAutomatically = enabled
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        if enabled {
            try? Self.loginAgent.register()
        } else {
            try? Self.loginAgent.unregister()
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
                Text("Hold ⌘⇧ and scroll up from anywhere to go back in time.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.columns)
        .padding(28)
    }
}
