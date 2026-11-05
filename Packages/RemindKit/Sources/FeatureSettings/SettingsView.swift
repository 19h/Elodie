import AppKit
import DesignSystem
import Speech
import SwiftUI
import UniformTypeIdentifiers

/// The settings tabs, in the order they appear.
public enum SettingsTab: Int, CaseIterable, Sendable {
    case general, screen, audio, meetings, storage, shortcuts

    var title: String {
        switch self {
        case .general: String(localized: "General")
        case .screen: String(localized: "Screen")
        case .audio: String(localized: "Audio")
        case .meetings: String(localized: "Meetings")
        case .storage: String(localized: "Storage")
        case .shortcuts: String(localized: "Shortcuts")
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .screen: "display"
        case .audio: "waveform"
        case .meetings: "calendar"
        case .storage: "internaldrive"
        case .shortcuts: "keyboard"
        }
    }
}

/// Makes the settings window: the system's preferences toolbar, with a window that
/// resizes to fit each tab.
@MainActor
public enum SettingsWindow {
    public static func make(
        model: SettingsModel,
        actions: any SettingsActions,
        shortcuts: AnyView,
        selecting selected: SettingsTab = .general
    ) -> NSWindow {
        let window = NSWindow(contentViewController: controller(
            model: model,
            actions: actions,
            shortcuts: shortcuts,
            selecting: selected
        ))
        configure(window)
        return window
    }

    /// Gives a window the look settings needs.
    public static func configure(_ window: NSWindow) {
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.toolbarStyle = .preference
        window.title = String(localized: "Settings")
        window.isReleasedWhenClosed = false
    }

    public static func controller(
        model: SettingsModel,
        actions: any SettingsActions,
        shortcuts: AnyView,
        selecting selected: SettingsTab = .general
    ) -> NSViewController {
        let tabs = NSTabViewController()
        tabs.tabStyle = .toolbar
        tabs.canPropagateSelectedChildViewControllerTitle = false
        for tab in SettingsTab.allCases {
            let root = pane(for: tab, model: model, actions: actions, shortcuts: shortcuts)
                .frame(width: 640)
                .fixedSize(horizontal: false, vertical: true)
                .tint(Palette.verdigris)
            let hosting = NSHostingController(rootView: root)
            hosting.sizingOptions = [.preferredContentSize]
            let item = NSTabViewItem(viewController: hosting)
            item.label = tab.title
            item.image = NSImage(systemSymbolName: tab.symbol, accessibilityDescription: tab.title)
            tabs.addTabViewItem(item)
        }
        tabs.selectedTabViewItemIndex = selected.rawValue
        return tabs
    }

    @ViewBuilder
    private static func pane(
        for tab: SettingsTab,
        model: SettingsModel,
        actions: any SettingsActions,
        shortcuts: AnyView
    ) -> some View {
        switch tab {
        case .general: GeneralTab(model: model, actions: actions)
        case .screen: ScreenTab(model: model, actions: actions)
        case .audio: AudioTab(model: model)
        case .meetings: MeetingsTab(model: model, actions: actions)
        case .storage: StorageTab(model: model, actions: actions)
        case .shortcuts: shortcuts
        }
    }
}

private struct GeneralTab: View {
    @Bindable var model: SettingsModel
    let actions: any SettingsActions

    var body: some View {
        Form {
            Toggle("Open Remind at login", isOn: Binding(
                get: { actions.launchAtLogin },
                set: { actions.setLaunchAtLogin($0) }
            ))
            Toggle("Remind me when recording is paused", isOn: $model.remindWhenPaused)
            Toggle("Show in Dock", isOn: Binding(
                get: { model.showInDock },
                set: { actions.setShowInDock($0) }
            ))
            Toggle("Check for updates automatically", isOn: Binding(
                get: { model.checkForUpdates },
                set: { actions.setChecksForUpdates($0) }
            ))
        }
        .formStyle(.columns)
        .padding(28)
    }
}

private struct ScreenTab: View {
    @Bindable var model: SettingsModel
    let actions: any SettingsActions
    @State private var showRunningApps = false
    @State private var installed: [AppChoice] = []

    var body: some View {
        VStack(spacing: 18) {
            Text("Screen recordings stay on this Mac. They're never uploaded.")
                .font(.headline)
            Form {
                LabeledContent("Exclude apps:") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Windows from these apps are left out of recordings.")
                            .foregroundStyle(.secondary)
                        AppExclusionList(
                            choices: showRunningApps ? installed + actions.runningApps : installed,
                            excluded: $model.excludedApps
                        )
                        .frame(height: 190)
                        HStack(spacing: 10) {
                            Button {
                                addApp()
                            } label: {
                                Image(systemName: "plus").frame(width: 22)
                            }
                            .help("Choose an app to exclude")
                            Toggle("Show running apps", isOn: $showRunningApps)
                                .toggleStyle(.checkbox)
                        }
                    }
                }
                LabeledContent("Private browsing:") {
                    VStack(alignment: .leading, spacing: 6) {
                        Toggle(isOn: $model.excludePrivateWindows) {
                            Text("Don't record private or incognito browser windows")
                        }
                        .toggleStyle(.checkbox)
                        if let warning = model.privateBrowsingWarning {
                            Label(warning, systemImage: "exclamationmark.triangle.fill")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(.top, 8)
                LabeledContent("Text recognition:") {
                    VStack(alignment: .leading, spacing: 4) {
                        Picker("", selection: $model.textRecognition) {
                            Text("Standard").tag(TextRecognitionMode.standard)
                            Text("Additional languages").tag(TextRecognitionMode.additionalLanguages)
                        }
                        .labelsHidden()
                        Text("Additional languages use more system resources.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.top, 8)
            }
            .formStyle(.columns)
        }
        .padding(28)
        .task {
            installed = await Task.detached(priority: .userInitiated) { InstalledApps.scan() }.value
        }
    }

    private func addApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.applicationBundle]
        panel.directoryURL = URL(filePath: "/Applications")
        guard panel.runModal() == .OK, let url = panel.url,
              let id = Bundle(url: url)?.bundleIdentifier
        else { return }
        model.excludedApps.insert(id)
    }
}

/// The apps on this Mac.
enum InstalledApps {
    static func scan() -> [AppChoice] {
        let folders = [
            "/Applications",
            "/Applications/Utilities",
            "/System/Applications",
            "/System/Applications/Utilities",
            NSHomeDirectory() + "/Applications",
        ]
        let manager = FileManager.default
        return folders.flatMap { folder -> [AppChoice] in
            let names = (try? manager.contentsOfDirectory(atPath: folder)) ?? []
            return names.filter { $0.hasSuffix(".app") }.compactMap { name in
                let path = folder + "/" + name
                guard let id = Bundle(path: path)?.bundleIdentifier else { return nil }
                return AppChoice(bundleID: id, name: String(name.dropLast(4)), path: path)
            }
        }
    }
}

private struct AppExclusionList: View {
    let choices: [AppChoice]
    @Binding var excluded: Set<String>

    /// Every app offered, plus excluded ones that aren't. A running app can have several
    /// instances, and each app only gets one row.
    private var rows: [AppChoice] {
        var seen = Set<String>()
        var all = choices.filter { seen.insert($0.bundleID).inserted }
        for id in excluded where !seen.contains(id) {
            let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id)
            all.append(AppChoice(
                bundleID: id,
                name: url?.deletingPathExtension().lastPathComponent ?? id,
                path: url?.path ?? ""
            ))
        }
        return all.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        List(rows) { app in
            Toggle(isOn: Binding(
                get: { excluded.contains(app.bundleID) },
                set: { isOn in
                    if isOn { excluded.insert(app.bundleID) } else { excluded.remove(app.bundleID) }
                }
            )) {
                HStack(spacing: 8) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: app.path))
                        .resizable()
                        .frame(width: 22, height: 22)
                    Text(app.name)
                }
            }
            .toggleStyle(.checkbox)
        }
        .listStyle(.bordered(alternatesRowBackgrounds: true))
    }
}

private struct AudioTab: View {
    @Bindable var model: SettingsModel
    @State private var languages: [Locale] = []

    var body: some View {
        Form {
            Section {
                Text("Audio recordings stay on this Mac. They're never uploaded.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.bottom, 8)
            }
            LabeledContent("Transcription language:") {
                VStack(alignment: .leading, spacing: 4) {
                    Picker("", selection: $model.transcriptionLanguage) {
                        ForEach(languages, id: \.identifier) { locale in
                            Text(Locale.current.localizedString(forIdentifier: locale.identifier) ?? locale.identifier)
                                .tag(locale.identifier)
                        }
                    }
                    .labelsHidden()
                    Text("macOS downloads the language the first time it's used.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            LabeledContent("Record:") {
                VStack(alignment: .leading, spacing: 4) {
                    Picker("", selection: $model.audioSource) {
                        Text("Microphone and speaker audio").tag(AudioSource.microphoneAndSpeaker)
                        Text("Microphone only").tag(AudioSource.microphoneOnly)
                        Text("Speaker audio only").tag(AudioSource.speakerOnly)
                    }
                    .labelsHidden()
                    Text("This applies to meetings, and whenever audio capture is on in the menu.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.top, 8)
        }
        .formStyle(.columns)
        .padding(28)
        .task {
            let supported = await SpeechTranscriber.supportedLocales
            languages = supported.sorted {
                (Locale.current.localizedString(forIdentifier: $0.identifier) ?? "")
                    < (Locale.current.localizedString(forIdentifier: $1.identifier) ?? "")
            }
            // A Mac's own locale often isn't one speech supports, such as English in
            // Germany, and a picker with nothing selected looks broken.
            if !languages.contains(where: { $0.identifier == model.transcriptionLanguage }) {
                let current = Locale(identifier: model.transcriptionLanguage)
                let match = await SpeechTranscriber.supportedLocale(equivalentTo: current)
                    ?? languages.first { $0.language.languageCode == current.language.languageCode }
                    ?? languages.first
                if let match {
                    model.transcriptionLanguage = match.identifier
                }
            }
        }
    }
}

private struct MeetingsTab: View {
    @Bindable var model: SettingsModel
    let actions: any SettingsActions

    var body: some View {
        Form {
            LabeledContent("When a meeting is detected:") {
                VStack(alignment: .leading, spacing: 4) {
                    Picker("", selection: $model.meetingDetected) {
                        Text("Ask me").tag(MeetingDetectedChoice.ask)
                        Text("Record automatically").tag(MeetingDetectedChoice.recordAutomatically)
                        Text("Don't record").tag(MeetingDetectedChoice.doNotRecord)
                    }
                    .labelsHidden()
                    Text("Laws on recording conversations vary. Check that others are OK with being recorded.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            LabeledContent("Names:") {
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("Name meetings from your calendar", isOn: Binding(
                        get: { model.namesMeetingsFromCalendar },
                        set: { actions.setNamesMeetingsFromCalendar($0) }
                    ))
                    .toggleStyle(.checkbox)
                    Text("Remind reads the event that's on now, and only keeps its title with the transcript.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.top, 8)
        }
        .formStyle(.columns)
        .padding(28)
    }
}

private struct StorageTab: View {
    @Bindable var model: SettingsModel
    let actions: any SettingsActions

    @State private var usage: StorageUsage?
    @State private var pendingRetention: RetentionPeriod?
    @State private var confirmingDeleteAll = false
    @State private var isWorking = false

    var body: some View {
        Form {
            LabeledContent("Keep recordings for:") {
                VStack(alignment: .leading, spacing: 4) {
                    Picker("", selection: Binding(
                        get: { model.retention },
                        set: { new in
                            if new == .forever || isLonger(new, than: model.retention) {
                                model.retention = new
                            } else {
                                pendingRetention = new
                            }
                        }
                    )) {
                        ForEach(RetentionPeriod.allCases) { period in
                            Text(period.title).tag(period)
                        }
                    }
                    .labelsHidden()
                    Text("Keeping less saves space, and also limits how far back you can search.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            LabeledContent("Space used:") {
                VStack(alignment: .leading, spacing: 4) {
                    if let usage {
                        Text(usage.recordingBytes.formatted(.byteCount(style: .file)))
                        if let perDay = usage.bytesPerDay(now: Date()) {
                            Text("About \(perDay.formatted(.byteCount(style: .file))) a day, based on your recordings so far.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Text("\(usage.freeBytes.formatted(.byteCount(style: .file))) free on this disk.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        ProgressView().controlSize(.small)
                    }
                }
            }
            .padding(.top, 8)
            LabeledContent("Recovery key:") {
                VStack(alignment: .leading, spacing: 4) {
                    Button("Save recovery key…") { actions.saveRecoveryKey() }
                    Text("Without this, your history can't be recovered if the key in your keychain is ever lost.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.top, 8)
            LabeledContent("Location:") {
                Button("Show in Finder") { actions.revealVault() }
            }
            .padding(.top, 8)
            LabeledContent("") {
                Button("Delete all recordings…", role: .destructive) { confirmingDeleteAll = true }
                    .disabled(isWorking)
            }
            .padding(.top, 12)
        }
        .formStyle(.columns)
        .padding(28)
        .task { usage = await actions.storageUsage() }
        .alert(
            "Delete recordings older than \(pendingRetention.map { String(localized: $0.title) } ?? "")?",
            isPresented: Binding(get: { pendingRetention != nil }, set: { if !$0 { pendingRetention = nil } })
        ) {
            Button("Delete older recordings", role: .destructive) {
                guard let period = pendingRetention else { return }
                model.retention = period
                run { await actions.applyRetention(period) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This can't be undone.")
        }
        .alert("Delete all recordings?", isPresented: $confirmingDeleteAll) {
            Button("Delete all recordings", role: .destructive) {
                run { await actions.deleteAllData() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently deletes your screen recordings, audio, and transcripts. It can't be undone.")
        }
    }

    private func isLonger(_ a: RetentionPeriod, than b: RetentionPeriod) -> Bool {
        let order = RetentionPeriod.allCases
        return (order.firstIndex(of: a) ?? 0) > (order.firstIndex(of: b) ?? 0)
    }

    private func run(_ work: @escaping () async -> Void) {
        isWorking = true
        Task {
            await work()
            usage = await actions.storageUsage()
            isWorking = false
        }
    }
}
