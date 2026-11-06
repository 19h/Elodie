import AppKit
import WidgetKit
import AVFoundation
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
#if DEBUG
import FrameEngine
#endif
import Ingest
import KeyboardShortcuts
import ServiceManagement
import SwiftUI

extension KeyboardShortcuts.Name {
    static let search = Self("search", default: .init(.space, modifiers: [.command, .shift]))
    // Space is in the same place, and reads the same, on every keyboard layout.
    static let ask = Self("ask", default: .init(.space, modifiers: [.option, .shift]))
    static let dailyRecap = Self("dailyRecap")
    // ⇧⌘S is Save As in most apps, so stars have no global shortcut until one is
    // chosen. It works inside the overlay.
    static let starMoment = Self("starMoment")
    static let toggleAudio = Self("toggleAudio")
}

/// Why Elodie can't record, as shown to the user.
enum RecordingProblem: Equatable {
    case permissionMissing
    case keyMissing
    case keychainLocked
    case keychainDenied
    case diskFull
    case encoderFailed
    case notSaving
    case keptCrashing
    case other(String)

    var message: String {
        switch self {
        case .permissionMissing: String(localized: "Elodie needs Screen Recording permission.")
        case .keyMissing: String(localized: "The key for your recordings is missing from your keychain.")
        case .keychainLocked: String(localized: "Your keychain is locked, so recordings can't be opened yet.")
        case .keychainDenied: String(localized: "Elodie wasn't allowed to read its key from your keychain.")
        case .diskFull: String(localized: "Recording stopped because the disk is nearly full.")
        case .encoderFailed: String(localized: "Recording stopped because video encoding kept failing.")
        case .notSaving: String(localized: "Recordings aren't being saved to disk.")
        case .keptCrashing: String(localized: "Recording is paused because Elodie kept crashing.")
        case .other(let text): text
        }
    }

    /// Whether trying again might help. A full disk needs something else to change first.
    var canRetry: Bool {
        switch self {
        case .keychainLocked, .keychainDenied, .encoderFailed, .notSaving, .keptCrashing, .other: true
        case .permissionMissing, .keyMissing, .diskFull: false
        }
    }

    /// Whether recording starting again shows this has passed.
    var endsWhenRecording: Bool {
        switch self {
        case .permissionMissing, .encoderFailed, .notSaving, .other: true
        case .keyMissing, .keychainLocked, .keychainDenied, .diskFull, .keptCrashing: false
        }
    }
}

/// Where this run keeps its things. A test run passes `--sandbox <folder>`, so it can go
/// through first run without touching the real vault, key, or settings.
enum AppEnvironment {
    nonisolated(unsafe) static var sandbox: URL?

    /// A throwaway test run next to someone's own copy leaves the shortcuts, the swipe, and
    /// Control Center to that copy, so they carry on working as usual.
    static let isGuestBesideRealCopy: Bool = {
        #if DEBUG
        guard sandbox != nil, let identifier = Bundle.main.bundleIdentifier else { return false }
        return NSRunningApplication.runningApplications(withBundleIdentifier: identifier).count > 1
        #else
        return false
        #endif
    }()

    /// Whether this run stays off Control Center's channel. A test of it can ask to use it.
    static let leavesControlCenterAlone = isGuestBesideRealCopy && !CommandLine.arguments.contains("--control-channel")

    #if DEBUG
    /// Starts a driven run's save panels somewhere harmless, under a name that doesn't change.
    static func aim(_ panel: NSSavePanel, named name: String) {
        let arguments = CommandLine.arguments
        guard let flag = arguments.firstIndex(of: "--save-to"), arguments.indices.contains(flag + 1) else { return }
        panel.directoryURL = URL(filePath: arguments[flag + 1], directoryHint: .isDirectory)
        panel.nameFieldStringValue = name
    }
    #endif

    nonisolated(unsafe) static let defaults: UserDefaults = {
        guard sandbox != nil, let suite = UserDefaults(suiteName: "elodie-sandbox") else { return .standard }
        return suite
    }()

    static var vaultDirectory: URL {
        if let sandbox {
            return sandbox.appending(path: "vault", directoryHint: .isDirectory)
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appending(path: Bundle.main.bundleIdentifier ?? "app.elodie.Elodie", directoryHint: .isDirectory)
            .appending(path: "vault", directoryHint: .isDirectory)
    }
}

/// Starts everything, and owns the app's top-level state.
@MainActor
final class AppController: NSObject {
    /// Below this, background OCR catch-up pauses.
    static let lowDiskBytes: Int64 = 10_000_000_000
    /// Below this, recording stops.
    static let criticalDiskBytes: Int64 = 2_000_000_000

    let settings = SettingsModel(defaults: AppEnvironment.defaults)
    private let permissions = PermissionMonitor(defaults: AppEnvironment.defaults, accessibility: Edition.accessibility)
    private var core: LiveCore?
    private var recording: RecordingController?
    private var ocr: OCRWorker?
    private var overlay: OverlayCoordinator?
    private var menu: StatusMenu?
    private var onboardingWindow: NSWindow?
    private var recoveryWindow: NSWindow?
    private var settingsWindow: NSWindow?
    private var askWindow: NSWindow?
    private var recapWindow: NSWindow?
    private var transcriptWindow: NSWindow?
    private var transcriptsWindow: NSWindow?
    private var publishedState: RecordingChannel.State?
    private var promptPanel: NSPanel?
    private var audio: AudioRecorder?
    private var meetingTimer: Timer?
    private var currentMeeting: DetectedMeeting?
    private var dismissedMeeting: DetectedMeeting?
    private var audioStarted: Date?
    private var meetingGoneSince: Date?
    private let inventory = WindowInventory()
    private let calendar = MeetingCalendar()
    private var transcriptTitle: String?
    private(set) var audioProblem: String?
    private(set) var isTranscribing = false
    /// Set once the app is running, so Shortcuts actions and the Control Center button can
    /// reach it.
    private(set) static weak var shared: AppController?
    private var scrollMonitor: ScrollToOpen?
    private var resumeTimer: Timer?
    private var maintenanceTimer: Timer?
    private var pausedAlert: Timer?
    private var lastRetention = Date()
    private var lastStartAttempt = Date.distantPast
    private var lastAppendFailures: UInt64 = 0
    private var isOpeningVault = false
    private var isScreenLocked = false
    private var pendingMoment: Date?
    private var windowObservers: [NSWindow: any NSObjectProtocol] = [:]
    private let launchedAt = Date()
    private let crashGuard = CrashGuard(defaults: AppEnvironment.defaults)
    private static let loginAgent = Edition.loginItem
    private(set) var problem: RecordingProblem?
    private(set) var isPaused = false

    private var vaultDirectory: URL { AppEnvironment.vaultDirectory }
    private var defaults: UserDefaults { AppEnvironment.defaults }

    /// Whether recordings can be read yet. Menu rows that need them stay disabled until then.
    #if DEBUG
    /// Draws the everyday menu in a screenshot, with nothing set up and no settings changed.
    var debugPretendsSetUp = false
    var isVaultOpen: Bool { core != nil || debugPretendsSetUp }
    var hasFinishedOnboarding: Bool { settings.hasFinishedOnboarding || debugPretendsSetUp }
    #else
    var isVaultOpen: Bool { core != nil }
    var hasFinishedOnboarding: Bool { settings.hasFinishedOnboarding }
    #endif

    /// Whether frames are really being captured at this moment.
    var isRecording: Bool {
        if case .recording = recording?.currentState { return true }
        return false
    }

    func start() {
        Self.shared = self
        #if DEBUG
        if let sandbox = AppEnvironment.sandbox { startSandboxDriver(in: sandbox) }
        #endif
        listenForControlCenter()
        NSApp.setActivationPolicy(settings.showInDock ? .regular : .accessory)
        NSApp.mainMenu = MainMenu.make(controller: self)
        if crashGuard.launchShouldStayPaused() {
            isPaused = true
            problem = .keptCrashing
        } else {
            restorePause()
        }
        isScreenLocked = Self.readScreenIsLocked()
        menu = StatusMenu(controller: self)
        registerShortcuts()
        observeSystemEvents()

        // Someone who has finished setup keeps their history, whatever has happened to
        // permissions since. Those show up as a problem to fix, not as starting over.
        if settings.hasFinishedOnboarding {
            openVaultAndRecord()
        } else {
            showOnboarding()
        }
    }

    /// Gets ready to quit, and returns what's left to finish. Audio can take a moment, because
    /// what's being said right now only becomes words when it's told to finish. The work it
    /// returns can't rely on the main actor: see `AppDelegate.applicationShouldTerminate`.
    func prepareToQuit() -> @Sendable () async -> Void {
        if isTranscribing {
            stopTranscribing()
        }
        crashGuard.markCleanExit()
        let audio = self.audio
        let core = self.core
        return {
            await audio?.stop()
            try? core?.sealAll()
        }
    }

    private func registerShortcuts() {
        #if DEBUG
        // Only the swipe, with keys another copy isn't listening for. See `handleScroll`.
        if OverlayCoordinator.usesTestSwipeKeys {
            startScrollMonitor()
            return
        }
        #endif
        guard !AppEnvironment.isGuestBesideRealCopy else { return }
        KeyboardShortcuts.onKeyDown(for: .search) { [weak self] in self?.showSearch() }
        KeyboardShortcuts.onKeyDown(for: .ask) { [weak self] in self?.openAsk() }
        KeyboardShortcuts.onKeyDown(for: .dailyRecap) { [weak self] in self?.openRecap() }
        KeyboardShortcuts.onKeyDown(for: .starMoment) { [weak self] in self?.starMoment() }
        KeyboardShortcuts.onKeyDown(for: .toggleAudio) { [weak self] in self?.toggleTranscribing() }
        startScrollMonitor()
    }

    private func startScrollMonitor() {
        let monitor = ScrollToOpen { [weak self] event in self?.overlay?.handleScroll(event) }
        monitor.start()
        scrollMonitor = monitor
    }

    /// What clicking the app again should do, which depends on what's needed next.
    func handleReopen() {
        if !settings.hasFinishedOnboarding {
            showOnboarding()
        } else if problem == .keyMissing {
            showRecovery()
        } else if isVaultOpen {
            showSearch()
        } else {
            openSettings()
        }
    }

    // MARK: Opening the vault

    private enum OpenFailure: Error {
        case key(KeyStore.Failure)
        case wrongKey
        case busy
        case other(String)
    }

    private nonisolated static func vaultExists(at directory: URL) -> Bool {
        let manager = FileManager.default
        if manager.fileExists(atPath: directory.appending(path: "vault.db").path) { return true }
        // Recordings without their database can still be rebuilt, but only with their key.
        let chunks = directory.appending(path: "chunks", directoryHint: .isDirectory)
        return !((try? manager.contentsOfDirectory(atPath: chunks.path)) ?? []).isEmpty
    }

    private func openVaultAndRecord() {
        guard !isOpeningVault, core == nil else { return }
        isOpeningVault = true
        let directory = vaultDirectory
        // Reading the key can put up a keychain prompt, and recovery can take a moment, so
        // none of this happens on the main thread.
        Task.detached(priority: .userInitiated) { [weak self] in
            let result: Result<LiveCore, OpenFailure>
            do {
                let key = try KeyStore.key(vaultExists: Self.vaultExists(at: directory))
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                result = .success(try LiveCore(vaultDirectory: directory, masterKey: key))
            } catch let failure as KeyStore.Failure {
                result = .failure(.key(failure))
            } catch {
                if LiveCore.isVaultBusy(error) {
                    result = .failure(.busy)
                } else if LiveCore.isWrongKey(error) {
                    result = .failure(.wrongKey)
                } else {
                    result = .failure(.other(String(describing: error)))
                }
            }
            await self?.finishOpening(result)
        }
    }

    private func finishOpening(_ result: Result<LiveCore, OpenFailure>) {
        isOpeningVault = false
        switch result {
        case .success(let core):
            didOpen(core)
        case .failure(.busy):
            // Another copy has the vault, and only one can record.
            NSApp.terminate(nil)
        case .failure(.wrongKey), .failure(.key(.keyMissing)):
            show(problem: .keyMissing)
            showRecovery()
        case .failure(.key(.keychainLocked)):
            // This clears itself: unlocking the screen tries again.
            show(problem: .keychainLocked)
        case .failure(.key(.accessDenied)):
            show(problem: .keychainDenied)
        case .failure(.key(.keychainUnavailable(let status))):
            show(problem: .other(String(localized: "The keychain couldn't be read (\(status)).")))
        case .failure(.key(.couldNotCreate(let status))):
            show(problem: .other(String(localized: "Couldn't create a key for your recordings (\(status)).")))
        case .failure(.other(let reason)):
            show(problem: .other(String(localized: "Your recordings couldn't be opened: \(reason)")))
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
        excludeFromBackups(vaultDirectory)
        if problem != .keptCrashing {
            problem = nil
        }
        closeRecovery()
        reportUnreadableRecordings(core)

        let overlay = OverlayCoordinator(core: core)
        overlay.onOpenChange = { [weak self] isOpen in self?.scrollMonitor?.isOverlayOpen = isOpen }
        overlay.onOpenTranscript = { [weak self] time in self?.openTranscript(containing: time) }
        overlay.settings = { [weak self] in self?.openSettings() }
        overlay.isCapturing = { [weak self] in !(self?.isPaused ?? true) }
        overlay.isListening = { [weak self] in self?.isTranscribing ?? false }
        overlay.setCapturing = { [weak self] capturing in self?.setPaused(!capturing) }
        overlay.toggleListening = { [weak self] in self?.toggleTranscribing() }
        overlay.prepareToDelete = { [weak self] interval in self?.audio?.forget(through: interval.end) }
        overlay.onRecordingsDeleted = { [weak self] in self?.closeWindowsShowingRecordings() }
        overlay.searchNote = { [weak self] in
            guard self?.ocr?.isWarmingUp == true else { return nil }
            return String(localized: "Elodie is getting ready to read your screen, which takes a minute or so the first time. New recordings turn up here after that.")
        }
        self.overlay = overlay

        let worker = OCRWorker(core: core)
        worker.usesAdditionalLanguages = settings.textRecognition == .additionalLanguages
        worker.start()
        ocr = worker

        let recording = RecordingController(core: core, policy: currentPolicy(), readFrontWindow: Edition.readFrontWindow)
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
        let audio = AudioRecorder(core: core)
        audio.onFailure = { [weak self] reason in
            DispatchQueue.main.async { self?.audioFailed(reason) }
        }
        self.audio = audio
        observeSettings()
        startRecording()
        applyRetention()
        startMaintenance()
        startMeetingWatch()
        if let pendingMoment {
            self.pendingMoment = nil
            overlay.open(at: pendingMoment)
        }
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

    // MARK: Recovery

    func showRecovery() {
        if let recoveryWindow {
            show(recoveryWindow)
            return
        }
        let view = RecoveryView(
            onRestore: { [weak self] text in await self?.restore(from: text) ?? .failed("") },
            onStartOver: { [weak self] in self?.startOver() },
            onQuit: { NSApp.terminate(nil) }
        )
        let window = NSWindow(contentViewController: NSHostingController(rootView: view))
        window.title = String(localized: "Unlock Elodie")
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.center()
        recoveryWindow = window
        show(window)
    }

    private func closeRecovery() {
        recoveryWindow?.close()
        recoveryWindow = nil
    }

    private func restore(from text: String) async -> RecoveryView.Outcome {
        guard let key = RecoveryKey.parse(text) else { return .notAKey }
        let directory = vaultDirectory
        // Only a key that really opens these recordings goes in the keychain.
        let opened: Result<LiveCore, any Error> = await Task.detached(priority: .userInitiated) {
            Result { try LiveCore(vaultDirectory: directory, masterKey: key) }
        }.value
        switch opened {
        case .success(let core):
            do {
                try KeyStore.restore(key)
            } catch {
                return .failed(String(localized: "It worked, but it couldn't be saved to your keychain."))
            }
            defaults.set(true, forKey: "recoveryKeySaved")
            didOpen(core)
            return .restored
        case .failure(let error):
            return LiveCore.isWrongKey(error) ? .wrongKey : .failed(error.localizedDescription)
        }
    }

    /// Deletes recordings that can never be read, after someone has said to.
    private func startOver() {
        do {
            try FileManager.default.removeItem(at: vaultDirectory)
        } catch {
            showAlert(
                String(localized: "Your recordings couldn't be deleted"),
                detail: error.localizedDescription
            )
            return
        }
        KeyStore.remove()
        closeRecovery()
        problem = nil
        openVaultAndRecord()
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
        audioProblem = nil
        menu?.refresh()
        let wantsMicrophone = settings.audioSource != .speakerOnly
        let wantsSpeakers = settings.audioSource != .microphoneOnly
        let locale = Locale(identifier: settings.transcriptionLanguage)
        let excluded = settings.excludedApps
        Task {
            var useMicrophone = wantsMicrophone
            if wantsMicrophone {
                useMicrophone = await Self.microphoneAllowed()
                if !useMicrophone {
                    if wantsSpeakers {
                        showAudioNotice(
                            String(localized: "Elodie can't hear your microphone"),
                            detail: String(localized: "Only your computer's audio is being transcribed. Allow the microphone in System Settings to include your voice.")
                        )
                    } else {
                        audioFailed(String(localized: "Elodie isn't allowed to use the microphone."))
                        return
                    }
                }
            }
            do {
                try await audio.start(
                    sources: AudioSources(microphone: useMicrophone, speakers: wantsSpeakers),
                    locale: locale,
                    title: title,
                    excluding: excluded
                )
            } catch is CancellationError {
                // Turned off while it was still starting, which is fine.
            } catch TranscriberError.languageNotSupported {
                audioFailed(String(localized: "That transcription language isn't available on this Mac. Choose another in Settings."))
            } catch {
                audioFailed(String(localized: "Transcription couldn't start: \(error.localizedDescription)"))
            }
        }
    }

    private nonisolated static func microphoneAllowed() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: true
        case .notDetermined: await AVCaptureDevice.requestAccess(for: .audio)
        default: false
        }
    }

    private func audioFailed(_ reason: String) {
        guard isTranscribing else { return }
        finishTranscript()
        audioProblem = reason
        Task { await audio?.stop() }
        showAudioNotice(String(localized: "Transcription stopped"), detail: reason)
        menu?.refresh()
    }

    private func showAudioNotice(_ title: String, detail: String) {
        showCard(NoticeCard(
            symbol: "waveform.slash",
            title: LocalizedStringKey(title),
            detail: LocalizedStringKey(detail),
            primary: "Open Settings",
            secondary: "Not now",
            onPrimary: { [weak self] in
                self?.closeMeetingPrompt()
                if let url = Permission.microphone.settingsURLIfDenied {
                    NSWorkspace.shared.open(url)
                } else {
                    self?.openSettings()
                }
            },
            onSecondary: { [weak self] in self?.closeMeetingPrompt() }
        ))
    }

    /// Notes the meeting and updates state. The audio itself is stopped separately.
    private func finishTranscript() {
        guard isTranscribing else { return }
        isTranscribing = false
        if let audioStarted {
            let interval = DateInterval(start: audioStarted, end: Date())
            let title = transcriptTitle
            Task.detached(priority: .utility) { [core] in
                try? core?.recordMeeting(title: title, from: interval.start, to: interval.end)
            }
        }
        audioStarted = nil
        menu?.refresh()
    }

    private func stopTranscribing() {
        guard isTranscribing else { return }
        finishTranscript()
        Task { await audio?.stop() }
    }

    var currentMeetingName: String? { currentMeeting?.app }

    /// Every transcript, including those from before this launch.
    func openTranscripts() {
        guard let core else { return }
        if transcriptsWindow == nil {
            let view = TranscriptsView(core: core) { [weak self] session in
                self?.openTranscript(session)
            }
            transcriptsWindow = makeWindow(title: "Transcripts", content: view, size: NSSize(width: 480, height: 560))
        }
        show(transcriptsWindow)
    }

    /// The transcript something said at this moment belongs to.
    func openTranscript(containing time: Date) {
        guard let core else { return }
        Task { [weak self] in
            let sessions = await Task.detached(priority: .userInitiated) {
                (try? core.transcriptSessions(from: time, to: time, limit: 1)) ?? []
            }.value
            let session = sessions.first ?? TranscriptSession(
                title: nil,
                start: time.addingTimeInterval(-300),
                end: time.addingTimeInterval(300),
                lines: 0
            )
            self?.openTranscript(session)
        }
    }

    private func openTranscript(_ session: TranscriptSession) {
        guard let core else { return }
        let view = TranscriptView(
            core: core,
            interval: DateInterval(start: session.start, end: max(session.end, session.start)),
            title: session.title
        ) { [weak self] time in
            self?.overlay?.open(at: time)
        }
        // A new window each time would leave a trail of them, and one is all anyone reads.
        transcriptWindow?.close()
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
        // Every window, not only those on screen. A call moved to another Space or minimized
        // is still a call, and transcription shouldn't stop because of it.
        let isMicrophoneInUse = MeetingDetector.isMicrophoneInUse
        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let windows = inventory.allWindows().filter { $0.layer == 0 }.map { window in
            let identity = inventory.identify(window.ownerPID)
            // A call in a browser only shows in its address, and only the front tab can be
            // read. Nothing is read unless the microphone is on, so this is rarely asked.
            var url: String?
            if isMicrophoneInUse, window.ownerPID == front, let family = identity.family,
               case .success(let info) = Edition.readFrontWindow(window.ownerPID, family) {
                url = info.url
            }
            return MeetingSignals.Window(bundleID: identity.bundleID, title: window.title, url: url)
        }
        var detected = MeetingDetector.detect(MeetingSignals(
            windows: windows,
            isMicrophoneInUse: isMicrophoneInUse
        ))
        // Switching away from the tab doesn't end the call. The microphone being let go does.
        if detected == nil, let current = currentMeeting, isMicrophoneInUse, current.isInBrowser {
            detected = current
        }
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

    private func showAlert(_ title: String, detail: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        NSApp.activate()
        alert.runModal()
    }

    // MARK: Control Center

    /// The Control Center button runs in a separate sandboxed process, and it signals
    /// through this notification, which can't carry any data.
    private func listenForControlCenter() {
        guard !AppEnvironment.leavesControlCenterAlone else { return }
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        let observer = Unmanaged.passUnretained(self).toOpaque()
        CFNotificationCenterAddObserver(center, observer, { _, _, _, _, _ in
            DispatchQueue.main.async { AppController.shared?.setPaused(true) }
        }, RecordingChannel.pauseRequest as CFString, nil, .deliverImmediately)
        CFNotificationCenterAddObserver(center, observer, { _, _, _, _, _ in
            DispatchQueue.main.async { AppController.shared?.setPaused(false) }
        }, RecordingChannel.resumeRequest as CFString, nil, .deliverImmediately)
    }

    /// Tells the Control Center button what's really happening, when that's changed.
    func publishRecordingState() {
        let state: RecordingChannel.State = isRecording ? .recording : .paused
        guard state != publishedState, !AppEnvironment.leavesControlCenterAlone else { return }
        publishedState = state
        RecordingChannel.publish(state)
        ControlCenter.shared.reloadControls(ofKind: RecordingChannel.controlKind)
    }

    func togglePaused() {
        setPaused(!isPaused)
    }

    /// Opens the timeline at a moment, from a link or a Shortcuts action. A link can arrive
    /// before recordings are open, so it waits for them.
    func showMoment(at time: Date) {
        if let overlay {
            overlay.open(at: time)
        } else {
            pendingMoment = time
        }
    }

    /// Permanently deletes the last 5 minutes.
    func forgetRecent() {
        guard let core else { return }
        let now = Date()
        audio?.forget(through: now)
        Task { [weak self] in
            do {
                try await Task.detached(priority: .userInitiated) {
                    _ = try core.deleteRange(from: now.addingTimeInterval(-5 * 60), to: now)
                }.value
                self?.overlay?.recordingsChanged()
            } catch {
                self?.showAlert(
                    String(localized: "The last 5 minutes couldn't be deleted"),
                    detail: error.localizedDescription
                )
            }
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
        guard let recording, !isPaused, !isScreenLocked, problem != .diskFull else { return }
        guard CGPreflightScreenCaptureAccess() else {
            show(problem: .permissionMissing)
            return
        }
        lastStartAttempt = Date()
        recording.update(policy: currentPolicy())
        Task {
            do {
                try await recording.start()
            } catch {
                recordingStopped(StreamStop(error))
            }
        }
    }

    private func recordingChanged(_ state: RecordingState) {
        switch state {
        case .recording:
            if problem?.endsWhenRecording == true {
                problem = nil
                closeMeetingPrompt()
            }
        case .interrupted(let reason):
            recordingStopped(reason)
        case .stopped:
            break
        }
        menu?.refresh()
    }

    private func recordingStopped(_ reason: StreamStop) {
        switch reason {
        case .stoppedByUser:
            setPaused(true)
        case .displayGone:
            startRecording()
        case .encoderFailed:
            show(problem: .encoderFailed)
        case .permissionMissing:
            show(problem: .permissionMissing)
        case .stoppedBySystem:
            // macOS stops capture for several reasons, and permission is only one of them.
            if CGPreflightScreenCaptureAccess() {
                show(problem: .other(String(localized: "macOS stopped the recording. Elodie will try again shortly.")))
            } else {
                show(problem: .permissionMissing)
            }
        case .other(let code):
            show(problem: .other(String(localized: "Recording stopped unexpectedly (\(code)). Elodie will try again shortly.")))
        }
    }

    private func show(problem: RecordingProblem) {
        let isNew = problem != self.problem
        self.problem = problem
        menu?.refresh()
        if isNew {
            announce(problem)
        }
    }

    /// A problem that stops recording has to be seen, or days of history could go missing.
    private func announce(_ problem: RecordingProblem) {
        switch problem {
        case .keyMissing:
            break // The recovery window says all of this.
        case .permissionMissing:
            showCard(NoticeCard(
                symbol: "rectangle.dashed.badge.record",
                title: "Elodie has stopped recording",
                detail: "It needs Screen Recording permission. If it's already on, reopening Elodie applies it.",
                primary: "Open System Settings",
                secondary: "Reopen Elodie",
                onPrimary: { [weak self] in
                    self?.openPermissionSettings()
                },
                onSecondary: { [weak self] in self?.relaunch() }
            ))
        case .diskFull:
            showCard(NoticeCard(
                symbol: "externaldrive.badge.exclamationmark",
                title: "Elodie has stopped recording",
                detail: "The disk is nearly full. Recording starts again when there's space, or you can keep less in Settings.",
                primary: "Open Settings",
                secondary: "Not now",
                onPrimary: { [weak self] in
                    self?.closeMeetingPrompt()
                    self?.openSettings()
                },
                onSecondary: { [weak self] in self?.closeMeetingPrompt() }
            ))
        case .keychainLocked:
            break // It usually clears by itself the moment the screen is unlocked.
        default:
            showCard(NoticeCard(
                symbol: "exclamationmark.triangle",
                title: "Elodie has stopped recording",
                detail: LocalizedStringKey(problem.message),
                primary: "Try again",
                secondary: "Not now",
                onPrimary: { [weak self] in
                    self?.closeMeetingPrompt()
                    self?.tryAgain()
                },
                onSecondary: { [weak self] in self?.closeMeetingPrompt() }
            ))
        }
    }

    func openPermissionSettings() {
        NSWorkspace.shared.open(Permission.screenRecording.settingsURL)
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
        pausedAlert?.invalidate()
        pausedAlert = nil
        if paused {
            savePause(until: duration.map { Date().addingTimeInterval($0) } ?? .distantFuture)
            Task { await recording?.stop() }
            scheduleEndOfPause(duration: duration)
        } else {
            savePause(until: nil)
            // Turning recording back on is the answer to having come back paused after crashes.
            if problem == .keptCrashing { problem = nil }
            startRecording()
        }
        menu?.refresh()
    }

    private func scheduleEndOfPause(duration: TimeInterval?) {
        if let duration {
            resumeTimer = Timer.scheduledTimer(withTimeInterval: duration, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.setPaused(false) }
            }
        } else {
            // Open-ended pauses are easy to forget, and the cost is a gap in your history.
            pausedAlert = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.alertPaused() }
            }
        }
    }

    /// A pause is a decision about privacy, so it survives a crash or a restart.
    private func savePause(until date: Date?) {
        if let date {
            defaults.set(date, forKey: "pausedUntil")
        } else {
            defaults.removeObject(forKey: "pausedUntil")
        }
    }

    private func restorePause() {
        guard let until = defaults.object(forKey: "pausedUntil") as? Date else { return }
        if until == .distantFuture {
            isPaused = true
            scheduleEndOfPause(duration: nil)
        } else if until > Date() {
            isPaused = true
            scheduleEndOfPause(duration: until.timeIntervalSinceNow)
        } else {
            savePause(until: nil)
        }
    }

    private var observers: [Any] = []

    private func observeSystemEvents() {
        let workspace = NSWorkspace.shared.notificationCenter
        observers.append(workspace.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.stopForAbsence() }
        })
        observers.append(workspace.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.resumeAfterAbsence() }
        })
        observers.append(workspace.addObserver(forName: NSWorkspace.sessionDidResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.isScreenLocked = true
                self?.stopForAbsence()
            }
        })
        observers.append(workspace.addObserver(forName: NSWorkspace.sessionDidBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.isScreenLocked = Self.readScreenIsLocked()
                self?.resumeAfterAbsence()
            }
        })
        let distributed = DistributedNotificationCenter.default()
        observers.append(distributed.addObserver(forName: Notification.Name("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.isScreenLocked = true
                self?.stopForAbsence()
            }
        })
        observers.append(distributed.addObserver(forName: Notification.Name("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.isScreenLocked = false
                self?.resumeAfterAbsence()
            }
        })
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.startRecording() }
        })
    }

    private nonisolated static func readScreenIsLocked() -> Bool {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return session["CGSSessionScreenIsLocked"] as? Bool ?? false
    }

    /// Nothing is recorded or heard while nobody's here. Everything recorded so far reaches
    /// the drive first.
    private func stopForAbsence() {
        stopTranscribing()
        overlay?.dismiss()
        let core = self.core
        Task {
            await recording?.stop()
            await Task.detached(priority: .utility) { try? core?.sealAll() }.value
        }
    }

    private func resumeAfterAbsence() {
        // Unlocking is also what a locked keychain was waiting for.
        if problem == .keychainLocked {
            problem = nil
            openVaultAndRecord()
        }
        startRecording()
        menu?.refresh()
    }

    private func alertPaused() {
        guard settings.alertWhenPaused else { return }
        showCard(NoticeCard(
            symbol: "pause.circle",
            title: "Elodie is still paused",
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
    private func suggestRecoveryKey(now: Date = Date()) {
        guard let firstRun = defaults.object(forKey: "firstRunDate") as? Date else {
            defaults.set(now, forKey: "firstRunDate")
            return
        }
        guard now.timeIntervalSince(firstRun) > 7 * 86_400,
              !defaults.bool(forKey: "recoveryKeySaved"),
              !defaults.bool(forKey: "recoveryKeySuggestionShown"),
              promptPanel == nil
        else { return }
        defaults.set(true, forKey: "recoveryKeySuggestionShown")
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
        guard maintenanceTimer == nil else { return }
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
        checkWrites()
        updatePrivacyWarning()
        suggestRecoveryKey(now: now)
        restartIfStopped(now: now)
        // Without this, an app left running for months would keep expired recordings.
        if now.timeIntervalSince(lastRetention) > 3600 {
            lastRetention = now
            applyRetention()
        }
        if now.timeIntervalSince(launchedAt) > 600 {
            crashGuard.markStable()
        }
    }

    /// Recording should be running and isn't, for a reason that may have passed. Nobody
    /// should have to notice this and click something for their history to carry on.
    private func restartIfStopped(now: Date) {
        guard !isRecording, !isPaused, !isScreenLocked,
              now.timeIntervalSince(lastStartAttempt) > 30
        else { return }
        switch problem {
        case nil, .other, .notSaving:
            startRecording()
        case .permissionMissing:
            // A grant only reaches a new process, but one that's been there all along means
            // the problem was something else.
            if CGPreflightScreenCaptureAccess() { startRecording() }
        default:
            break
        }
    }

    /// The disk can refuse writes long before it looks full.
    private func checkWrites() {
        guard let core else { return }
        let stats = core.stats()
        defer { lastAppendFailures = stats.appendFailures }
        if stats.isDiskFull {
            if problem != .diskFull {
                Task { await recording?.stop() }
                show(problem: .diskFull)
            }
        } else if stats.appendFailures > lastAppendFailures, problem == nil {
            show(problem: .notSaving)
        } else if stats.appendFailures == lastAppendFailures, problem == .notSaving {
            problem = nil
            menu?.refresh()
        }
    }

    private func updatePrivacyWarning() {
        switch recording?.privacyCheckTrouble {
        case .accessibilityOff:
            settings.privateBrowsingWarning = Edition.privateWindowNote
        case .browserNotResponding(let bundleID):
            let name = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)?
                .deletingPathExtension().lastPathComponent ?? bundleID
            settings.privateBrowsingWarning = String(
                localized: "\(name) isn't responding to Elodie, so its windows aren't being recorded right now."
            )
        case nil:
            settings.privateBrowsingWarning = nil
        }
    }

    private func checkDisk() {
        // Not knowing how much space there is doesn't mean there's plenty, but the writes
        // themselves will say if it runs out.
        guard let free = (try? vaultDirectory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage
        else { return }
        ocr?.allowsBackfill = free >= Self.lowDiskBytes
        if free < Self.criticalDiskBytes {
            if problem != .diskFull {
                let core = self.core
                Task {
                    await recording?.stop()
                    await Task.detached(priority: .utility) { try? core?.sealAll() }.value
                }
                show(problem: .diskFull)
            }
        } else if problem == .diskFull, free > Self.criticalDiskBytes * 2 {
            problem = nil
            closeMeetingPrompt()
            startRecording()
            menu?.refresh()
        }
    }

    // MARK: Commands

    func showSearch() {
        overlay?.open(focusSearch: true)
    }

    /// Stars what's on screen now. That takes a moment: the screen may have changed since
    /// the last frame, so it asks for a new one, and waits for it to be stored.
    func starMoment() {
        guard let core, let recording else { return }
        let requested = Date()
        let display = RecordingController.activeDisplay()
        let uuid = ScreenContent.stableID(of: display)
        recording.keepNextFrame()
        let isCapturing = isRecording
        Task.detached(priority: .userInitiated) {
            guard let uuid else { return }
            var frame: FrameRef?
            // Frames arrive every few seconds, and commit in batches.
            for _ in 0..<(isCapturing ? 40 : 1) {
                let latest = try? core.lookup(display: uuid, at: .distantFuture)
                frame = latest
                if let latest, latest.capturedAt >= requested { break }
                try? await Task.sleep(for: .milliseconds(250))
            }
            guard let frame, (try? core.setStarred(true, frameID: frame.id)) != nil else { return }
            await self.overlay?.recordingsChanged()
        }
    }

    /// Deleted recordings can't stay on screen in another window.
    private func closeWindowsShowingRecordings() {
        for window in [recapWindow, askWindow, transcriptWindow, transcriptsWindow] {
            window?.close()
        }
        recapWindow = nil
        askWindow = nil
        transcriptWindow = nil
        transcriptsWindow = nil
    }

    /// Says so if opening the vault found recordings it can't read. This only comes up when
    /// the number grows, since nothing can be done about the old ones.
    private func reportUnreadableRecordings(_ core: LiveCore) {
        let unreadable = Int(core.unreadableChunks)
        let known = defaults.integer(forKey: "reportedUnreadableChunks")
        defaults.set(unreadable, forKey: "reportedUnreadableChunks")
        guard unreadable > known else { return }
        showCard(NoticeCard(
            symbol: "exclamationmark.triangle",
            title: "Some recordings couldn't be read",
            detail: "\(unreadable - known) pieces of your recordings are damaged, so what's in them can't be shown. Everything else is fine.",
            primary: "OK",
            secondary: "Open Settings",
            onPrimary: { [weak self] in self?.closeMeetingPrompt() },
            onSecondary: { [weak self] in
                self?.closeMeetingPrompt()
                self?.openSettings()
            }
        ))
    }

    func openAsk() {
        guard let core else { return }
        if askWindow == nil {
            let model = AskModel(engine: AskEngine(core: core))
            let view = AskView(model: model) { [weak self] hit in
                if hit.isTranscript {
                    self?.openTranscript(containing: hit.capturedAt)
                } else {
                    self?.overlay?.open(at: hit.capturedAt, display: hit.display)
                }
            }
            askWindow = makeWindow(title: "Ask Elodie", content: view, size: NSSize(width: 560, height: 680))
        }
        show(askWindow)
    }

    func openRecap() {
        guard let core else { return }
        // A fresh one each time, so an old window doesn't reopen on yesterday.
        recapWindow?.close()
        let view = RecapView(
            core: core,
            onOpenMoment: { [weak self] time in self?.overlay?.open(at: time) },
            onOpenTranscript: { [weak self] time in self?.openTranscript(containing: time) }
        )
        recapWindow = makeWindow(title: "Daily Recap", content: view, size: NSSize(width: 620, height: 720))
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

    /// Shows a window, with a Dock icon and a place in ⌘-Tab for as long as there is one.
    /// A window you can't switch back to is easily lost.
    private func show(_ window: NSWindow?) {
        guard let window else { return }
        if NSApp.activationPolicy() != .regular {
            NSApp.setActivationPolicy(.regular)
        }
        if windowObservers[window] == nil {
            windowObservers[window] = NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.windowClosed(window) }
            }
        }
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    private func windowClosed(_ window: NSWindow) {
        if let observer = windowObservers.removeValue(forKey: window) {
            NotificationCenter.default.removeObserver(observer)
        }
        if windowObservers.isEmpty, !settings.showInDock {
            NSApp.setActivationPolicy(.accessory)
        }
    }

    func openSettings() {
        if settingsWindow == nil {
            settingsWindow = SettingsWindow.make(
                model: settings,
                actions: self,
                shortcuts: AnyView(ShortcutsTab())
            )
            settingsWindow?.center()
        }
        show(settingsWindow)
    }

    /// The window can be closed and come back, at the same step.
    func showOnboarding() {
        if let onboardingWindow {
            show(onboardingWindow)
            return
        }
        let step = OnboardingStep(rawValue: defaults.string(forKey: "onboardingStep") ?? "") ?? .welcome
        let view = OnboardingView(
            permissions: permissions,
            step: step,
            appIcon: NSApp.applicationIconImage,
            onStepChange: { [defaults] in defaults.set($0.rawValue, forKey: "onboardingStep") },
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
        // Where it was left, including across the relaunch Screen Recording needs.
        window.setFrameAutosaveName("onboarding")
        onboardingWindow = window
        observers.append(NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.onboardingWindow = nil }
        })
        show(window)
    }

    /// macOS only applies a new Screen Recording grant to new processes. The new copy waits
    /// for this one to finish, because only one can have the vault.
    func relaunch() {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        configuration.arguments = [Entry.relaunchedArgument]
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, error in
            DispatchQueue.main.async {
                if let error {
                    // The new copy didn't start, so this one stays and says so.
                    let alert = NSAlert()
                    alert.messageText = String(localized: "Elodie couldn't reopen")
                    alert.informativeText = String(localized: "Quit it and open it again. \(error.localizedDescription)")
                    alert.runModal()
                } else {
                    NSApp.terminate(nil)
                }
            }
        }
    }

    private func finishOnboarding(openAtLogin: Bool) {
        if openAtLogin {
            setLaunchAtLogin(true)
        }
        settings.hasFinishedOnboarding = true
        defaults.removeObject(forKey: "onboardingStep")
        onboardingWindow?.close()
        onboardingWindow = nil
        openVaultAndRecord()
    }

    private func applyRetention() {
        let period = settings.retention
        Task {
            do {
                try await applyRetention(period)
            } catch {
                // It's tried again in an hour, and nobody asked for this right now.
            }
        }
    }
}

#if DEBUG
// MARK: Driving a sandboxed run

/// Lets a run under `--sandbox` be driven from outside: a command written to `<sandbox>/command`
/// runs here, and what it found lands in `<sandbox>/result`. Nothing takes the keyboard or the
/// pointer, so this can run while someone's working. It doesn't exist in release builds.
extension AppController {
    func startSandboxDriver(in sandbox: URL) {
        let command = sandbox.appending(path: "command")
        let result = sandbox.appending(path: "result")
        Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let text = try? String(contentsOf: command, encoding: .utf8) else { return }
                try? FileManager.default.removeItem(at: command)
                Task { @MainActor in
                    let answer = await self?.runDriverCommand(text.trimmingCharacters(in: .whitespacesAndNewlines)) ?? "gone"
                    try? (answer + "\n").write(to: result, atomically: true, encoding: .utf8)
                }
            }
        }
    }

    private func runDriverCommand(_ text: String) async -> String {
        let parts = text.split(separator: " ", maxSplits: 1).map(String.init)
        let argument = parts.count > 1 ? parts[1] : ""
        do {
            switch parts.first ?? "" {
            case "open":
                if OverlayCoordinator.opensAwayFromPointer {
                    // The picture from wherever recording happened, on the other display.
                    overlay?.open(display: try core?.displays().first?.id)
                } else {
                    overlay?.open(focusSearch: argument == "search")
                }
            case "search":
                overlay?.debugSearch(argument)
            case "choose":
                overlay?.debugChooseResult()
            case "esc":
                overlay?.debugEscape()
            case "dismiss":
                overlay?.dismiss()
            case "back":
                overlay?.debugMove(to: Date().addingTimeInterval(-(Double(argument) ?? 0)))
            case "star":
                overlay?.debugStar()
            case "click":
                let x = Double(argument) ?? 0
                overlay?.debugStrip(.down(x, clicks: 1))
                overlay?.debugStrip(.up(x))
            case "clickPlayhead":
                overlay?.debugClickPlayhead()
            case "deleteSelection":
                try await overlay?.debugDeleteSelection()
            case "exportSelection":
                try await overlay?.debugExportSelection(to: URL(filePath: argument))
            case "filterStarred":
                overlay?.debugFilterStarred()
            case "listen":
                toggleTranscribing()
            case "pause":
                togglePaused()
            case "recap":
                openRecap()
            case "ask":
                openAsk()
            case "transcripts":
                openTranscripts()
            case "settings":
                openSettings()
            case "shootPanel":
                guard let window = overlay?.debugPanelWindow else { return "no panel" }
                try await ScreenContent.saveScreenshot(ofWindow: window, to: URL(filePath: argument))
            case "shootWindow":
                try await ScreenContent.saveScreenshotOfLargestOwnWindow(to: URL(filePath: argument))
            case "askNow":
                guard let core else { return "no vault" }
                var sources = 0
                var answer = ""
                for await update in AskEngine(core: core).ask(argument) {
                    switch update {
                    case .sources(let found): sources = found.count
                    case .answer(let text): answer = text
                    case .noAnswer(let reason): answer = "(no answer) \(reason)"
                    }
                }
                return "sources: \(sources)\nanswer: \(answer)"
            case "startOver":
                startOver()
            case "restore":
                return "\(await restore(from: argument))"
            case "recoveryKey":
                return (try? RecoveryKey.text(for: KeyStore.key(vaultExists: true))) ?? "none"
            case "state":
                break
            case "hits":
                return overlay?.debugHits ?? "none"
            case "apps":
                return try core?.recordedApps().joined(separator: "\n") ?? "none"
            case "coreSearch":
                // Straight to the core, for a run with no overlay on anyone's screen.
                guard let core, let session = try core.search(argument, facets: SearchFacets(), order: .relevance) else { return "no session" }
                let hits = try session.nextPage().hits
                return "\(hits.count) hits\n" + hits.prefix(3).map { "\($0.bundleID ?? "?") \($0.window ?? "?") at \($0.capturedAt.timeIntervalSince1970): \($0.snippet)" }.joined(separator: "\n")
            case "coreDisplays":
                guard let core else { return "no vault" }
                return try core.displays().map { display in
                    let periods = try core.recordedPeriods(display: display.id, minimumGap: 30)
                    return "\(display.id) \(display.width)x\(display.height), \(periods.count) stretches"
                }.joined(separator: "\n")
            case "vaultPath":
                return vaultDirectory.path
            case "coreTranscript":
                guard let core else { return "no vault" }
                let lines = try core.transcript(from: Date().addingTimeInterval(-900), to: Date())
                return "\(lines.count) lines\n" + lines.map { "\($0.isMe ? "You" : "Others"): \($0.text)" }.joined(separator: "\n")
            case "panelExport":
                overlay?.debugExportLastMinute()
            case "panelImage":
                overlay?.debugSaveImage()
            case "panelRecovery":
                saveRecoveryKey()
            case "panelOpen":
                // What the recovery window and the excluded apps list do with a chosen file.
                let panel = NSOpenPanel()
                panel.allowedContentTypes = argument.hasSuffix(".app") ? [.applicationBundle] : [.plainText, .text]
                panel.directoryURL = URL(filePath: argument)
                NSApp.activate()
                guard panel.runModal() == .OK, let url = panel.url else { return "cancelled" }
                if url.pathExtension == "app" {
                    return "chose \(url.lastPathComponent), bundle ID \(Bundle(url: url)?.bundleIdentifier ?? "unreadable")"
                }
                let contents = try String(contentsOf: url, encoding: .utf8)
                return "chose \(url.lastPathComponent), read \(contents.utf8.count) bytes"
            case "useRecordedDisplay":
                overlay?.debugDisplayOverride = try core?.displays().first?.id
            case "coreExport":
                // The last minute of a display, into the folder this run was given.
                guard let core, let sandbox = AppEnvironment.sandbox, let display = try core.displays().first else { return "nothing" }
                let url = sandbox.appending(path: "clip.mp4")
                let summary = try await MP4Exporter.export(core: core, display: display.id, from: Date().addingTimeInterval(-60), to: Date(), to: url)
                let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                return "\(summary.frames) frames, \(size) bytes"
            case "lookup":
                guard let core, let time = Double(argument), let display = overlay?.debugDisplay,
                      let found = try core.lookup(display: display, at: Date(timeIntervalSince1970: time))
                else { return "nothing" }
                let group = try core.readGroup(containing: found.id)
                return "frame \(found.id) at \(found.capturedAt.timeIntervalSince1970), group \(group.samples.map { "\($0.frameID)\($0.isKeyframe ? "K" : "")" }.joined(separator: " "))"
            case "quit":
                NSApp.terminate(nil)
            default:
                return "unknown command \(text)"
            }
        } catch {
            return "failed: \(error)"
        }
        var state = overlay?.debugState ?? ["open": "no overlay"]
        state["lastResult"] = overlay?.debugLastResult ?? "none"
        state["paused"] = "\(isPaused)"
        state["listening"] = "\(isTranscribing)"
        state["problem"] = problem.map { "\($0)" } ?? "none"
        state["recording"] = recording.map { "\($0.currentState)" } ?? "none"
        if let core {
            let stats = core.stats()
            state["logged"] = "\(stats.loggedFrames)"
            state["indexed"] = "\(stats.indexedFrames)"
            state["dropped"] = "\(stats.droppedFrames)"
        }
        if let stats = recording?.pipelineStats {
            state["pipeline"] = "received \(stats.received), busy \(stats.busy), unchanged \(stats.unchanged), black \(stats.black), excluded \(stats.excluded), stored \(stats.stored)"
        }
        if let microphone = audio?.debugMicrophone {
            state["microphoneAudio"] = microphone
        }
        state["accessibility"] = "\(AXIsProcessTrusted())"
        state["screenRecording"] = "\(CGPreflightScreenCaptureAccess())"
        state["microphone"] = "\(AVCaptureDevice.authorizationStatus(for: .audio).rawValue)"
        state["eventTap"] = "\(scrollMonitor?.isUsingTap ?? false)"
        state["channel"] = "\(RecordingChannel.state)"
        state["ocrWarming"] = "\(ocr?.isWarmingUp ?? false)"
        state["ocrDone"] = "\(ocr?.framesProcessed ?? -1)"
        return state.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" }.joined(separator: "\n")
    }
}
#endif

// MARK: Settings

extension AppController: SettingsActions {
    func storageUsage() async -> StorageUsage {
        let directory = vaultDirectory
        let core = self.core
        return await Task.detached(priority: .utility) {
            let free = (try? directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
                .volumeAvailableCapacityForImportantUsage ?? 0
            let displays = (try? core?.displays()) ?? []
            return StorageUsage(
                recordingBytes: Self.allocatedSize(of: directory),
                freeBytes: free,
                oldest: displays.map(\.first).min(),
                apps: (try? core?.storageByApp()) ?? []
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

    private func requireCore() throws -> LiveCore {
        guard let core else {
            throw NSError(domain: "Elodie", code: 1, userInfo: [
                NSLocalizedDescriptionKey: String(localized: "Your recordings aren't open."),
            ])
        }
        return core
    }

    func deleteAllData() async throws {
        let core = try requireCore()
        audio?.forget(through: Date())
        try await Task.detached(priority: .userInitiated) {
            _ = try core.deleteRange(from: .distantPast, to: .distantFuture)
        }.value
        overlay?.recordingsChanged()
        closeWindowsShowingRecordings()
    }

    func deleteRange(_ interval: DateInterval) async throws {
        let core = try requireCore()
        audio?.forget(through: interval.end)
        try await Task.detached(priority: .userInitiated) {
            _ = try core.deleteRange(from: interval.start, to: interval.end)
        }.value
        overlay?.recordingsChanged()
        closeWindowsShowingRecordings()
    }

    func deleteRecordings(ofApp bundleID: String) async throws {
        let core = try requireCore()
        try await Task.detached(priority: .userInitiated) {
            for stretch in try core.appStretches(bundleID: bundleID) {
                _ = try core.deleteRange(from: stretch.start, to: stretch.end)
            }
        }.value
        overlay?.recordingsChanged()
        closeWindowsShowingRecordings()
    }

    func applyRetention(_ period: RetentionPeriod) async throws {
        guard let core, let cutoff = period.cutoff(now: Date()) else { return }
        try await Task.detached(priority: .utility) {
            _ = try core.deleteRange(from: .distantPast, to: cutoff)
        }.value
        overlay?.recordingsChanged()
        closeWindowsShowingRecordings()
    }

    func saveRecoveryKey() {
        Task { [weak self] in
            do {
                let key = try await Task.detached(priority: .userInitiated) {
                    try KeyStore.key(vaultExists: true)
                }.value
                self?.promptToSave(key)
            } catch {
                self?.showAlert(
                    String(localized: "The recovery key couldn't be read"),
                    detail: String(localized: "Your keychain may be locked. Try again in a moment.")
                )
            }
        }
    }

    private func promptToSave(_ key: Data) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Elodie recovery key.txt"
        #if DEBUG
        AppEnvironment.aim(panel, named: "recovery.txt")
        #endif
        panel.message = String(localized: "Keep this somewhere safe. Anyone with this key and your files can read your recordings.")
        NSApp.activate()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let text = """
        Elodie recovery key

        \(RecoveryKey.text(for: key))

        This decrypts your recordings. To use it, open Elodie on a Mac where the key is missing,
        and enter it when asked. Keep it somewhere safe and private.

        """
        // The file is private from the moment it exists, not from a moment later.
        try? FileManager.default.removeItem(at: url)
        guard FileManager.default.createFile(
            atPath: url.path,
            contents: Data(text.utf8),
            attributes: [.posixPermissions: 0o600]
        ) else {
            showAlert(
                String(localized: "The recovery key couldn't be saved"),
                detail: String(localized: "Choose another location and try again.")
            )
            return
        }
        defaults.set(true, forKey: "recoveryKeySaved")
    }

    func revealVault() {
        NSWorkspace.shared.activateFileViewerSelecting([vaultDirectory])
    }

    var launchAtLogin: Bool {
        guard AppEnvironment.sandbox == nil else { return false }
        return Self.loginAgent.status == .enabled
    }

    var loginItemNeedsApproval: Bool {
        guard AppEnvironment.sandbox == nil else { return false }
        return Self.loginAgent.status == .requiresApproval
    }

    func openLoginItemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    func setNamesMeetingsFromCalendar(_ enabled: Bool) {
        guard enabled else {
            settings.namesMeetingsFromCalendar = false
            return
        }
        // Asking happens now, when it's clear why, and not in the middle of a meeting.
        Task {
            let allowed = await calendar.requestAccess()
            settings.namesMeetingsFromCalendar = allowed
            if !allowed {
                showAlert(
                    String(localized: "Elodie can't read your calendar"),
                    detail: String(localized: "You can allow it in System Settings, under Privacy & Security, then Calendars.")
                )
            }
        }
    }

    func setShowInDock(_ show: Bool) {
        settings.showInDock = show
        if show || windowObservers.isEmpty {
            NSApp.setActivationPolicy(show ? .regular : .accessory)
        }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        guard AppEnvironment.sandbox == nil else { return }
        do {
            if enabled {
                try Self.loginAgent.register()
            } else {
                try Self.loginAgent.unregister()
            }
        } catch {
            showAlert(
                String(localized: "The login item couldn't be changed"),
                detail: error.localizedDescription
            )
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
            KeyboardShortcuts.Recorder("Search Elodie:", name: .search)
            KeyboardShortcuts.Recorder("Ask Elodie:", name: .ask)
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
