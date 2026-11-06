import AppKit
import CoreAPI
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
    /// macOS decides what this really is, so it's read back after every change.
    @State private var opensAtLogin = false
    @State private var needsApproval = false

    var body: some View {
        Form {
            Toggle("Open Elodie at login", isOn: Binding(
                get: { opensAtLogin },
                set: { newValue in
                    actions.setLaunchAtLogin(newValue)
                    refreshLoginItem()
                }
            ))
            if needsApproval {
                HStack(spacing: 8) {
                    Text("macOS is waiting for you to allow this.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Open Login Items") { actions.openLoginItemSettings() }
                        .controlSize(.small)
                }
            }
            Toggle("Alert me when recording is paused", isOn: $model.alertWhenPaused)
            Toggle("Show in Dock", isOn: Binding(
                get: { model.showInDock },
                set: { actions.setShowInDock($0) }
            ))
            LabeledContent("Help:") {
                HStack(spacing: 14) {
                    Link("Privacy policy", destination: ElodieLinks.privacyPolicy)
                    Link("Support", destination: ElodieLinks.support)
                }
            }
            .padding(.top, 8)
        }
        .formStyle(.columns)
        .padding(28)
        .onAppear(perform: refreshLoginItem)
    }

    private func refreshLoginItem() {
        opensAtLogin = actions.launchAtLogin
        needsApproval = actions.loginItemNeedsApproval
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
    /// In the App Sandbox, `NSHomeDirectory()` is the app's own container, which has no apps.
    private static var realHomeDirectory: String {
        getpwuid(getuid()).map { String(cString: $0.pointee.pw_dir) } ?? NSHomeDirectory()
    }

    static func scan() -> [AppChoice] {
        let folders = [
            "/Applications",
            "/Applications/Utilities",
            "/System/Applications",
            "/System/Applications/Utilities",
            realHomeDirectory + "/Applications",
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
                Text("Audio is turned into text on this Mac. The audio itself isn't kept, and nothing is uploaded.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
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
                    Text("Elodie reads the event that's on now, and only keeps its title with the transcript.")
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
    @State private var pendingApp: AppUsage?
    @State private var confirmingDeleteAll = false
    @State private var isChoosingRange = false
    @State private var confirmingRange = false
    @State private var rangeStart = Date().addingTimeInterval(-3600)
    @State private var rangeEnd = Date()
    @State private var isWorking = false
    @State private var failure: String?

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
                    Text("Keeping less saves space, and also limits how far back you can search. Starred moments aren't kept any longer than the rest.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
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
            if let apps = usage?.apps, !apps.isEmpty {
                LabeledContent("By app:") {
                    AppStorageList(apps: apps, onDelete: { pendingApp = $0 })
                        .frame(height: min(CGFloat(apps.count) * 28 + 2, 150))
                }
                .padding(.top, 8)
            }
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
            LabeledContent("Delete:") {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Button("Delete a time range…") {
                            rangeEnd = Date()
                            rangeStart = rangeEnd.addingTimeInterval(-3600)
                            isChoosingRange = true
                        }
                        .disabled(isWorking)
                        Button("Delete all recordings…", role: .destructive) { confirmingDeleteAll = true }
                            .disabled(isWorking)
                        if isWorking {
                            ProgressView().controlSize(.small)
                        }
                    }
                    Text("You can also select a stretch right on the timeline.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.top, 12)
        }
        .formStyle(.columns)
        .padding(28)
        .task { usage = await actions.storageUsage() }
        .sheet(isPresented: $isChoosingRange) { rangeSheet }
        .alert(
            "Delete recordings older than \(pendingRetention.map { String(localized: $0.title) } ?? "")?",
            isPresented: Binding(get: { pendingRetention != nil }, set: { if !$0 { pendingRetention = nil } })
        ) {
            Button("Delete older recordings", role: .destructive) {
                guard let period = pendingRetention else { return }
                model.retention = period
                run { try await actions.applyRetention(period) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This can't be undone.")
        }
        .alert("Delete all recordings?", isPresented: $confirmingDeleteAll) {
            Button("Delete all recordings", role: .destructive) {
                run { try await actions.deleteAllData() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently deletes your screen recordings and transcripts. It can't be undone.")
        }
        .alert(
            "Delete everything recorded from \(pendingApp.map(appName) ?? "this app")?",
            isPresented: Binding(get: { pendingApp != nil }, set: { if !$0 { pendingApp = nil } })
        ) {
            Button("Delete recordings", role: .destructive) {
                guard let bundleID = pendingApp?.bundleID else { return }
                run { try await actions.deleteRecordings(ofApp: bundleID) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently deletes those recordings and their text. It can't be undone, and Elodie keeps recording this app unless you exclude it in the Screen tab.")
        }
        .alert(
            "That couldn't be finished",
            isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(failure ?? "")
        }
    }

    private var rangeSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Delete a time range")
                .font(.headline)
            Form {
                DatePicker("From:", selection: $rangeStart, in: ...rangeEnd)
                DatePicker("To:", selection: $rangeEnd, in: rangeStart...Date())
            }
            .formStyle(.columns)
            Text("This permanently deletes screen recordings and transcripts from that time.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { isChoosingRange = false }
                    .keyboardShortcut(.cancelAction)
                Button("Delete", role: .destructive) {
                    isChoosingRange = false
                    let interval = DateInterval(start: rangeStart, end: rangeEnd)
                    run { try await actions.deleteRange(interval) }
                }
            }
        }
        .padding(24)
        .frame(width: 400)
    }

    private func isLonger(_ a: RetentionPeriod, than b: RetentionPeriod) -> Bool {
        let order = RetentionPeriod.allCases
        return (order.firstIndex(of: a) ?? 0) > (order.firstIndex(of: b) ?? 0)
    }

    private func appName(_ app: AppUsage) -> String {
        AppStorageList.name(of: app)
    }

    private func run(_ work: @escaping () async throws -> Void) {
        isWorking = true
        Task {
            do {
                try await work()
            } catch {
                failure = error.localizedDescription
            }
            usage = await actions.storageUsage()
            isWorking = false
        }
    }
}

/// How much each app takes up, with a way to remove it.
private struct AppStorageList: View {
    let apps: [AppUsage]
    let onDelete: (AppUsage) -> Void

    static func name(of app: AppUsage) -> String {
        guard let bundleID = app.bundleID else { return String(localized: "Other") }
        return NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)?
            .deletingPathExtension().lastPathComponent ?? bundleID
    }

    var body: some View {
        List(apps) { app in
            HStack(spacing: 8) {
                if let bundleID = app.bundleID,
                   let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                        .resizable()
                        .frame(width: 18, height: 18)
                } else {
                    Image(systemName: "app.dashed").frame(width: 18, height: 18)
                }
                Text(Self.name(of: app))
                    .lineLimit(1)
                Spacer()
                Text(app.bytes.formatted(.byteCount(style: .file)))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                if app.bundleID != nil {
                    Button {
                        onDelete(app)
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                    .help("Delete everything recorded from this app")
                    .accessibilityLabel("Delete recordings from \(Self.name(of: app))")
                }
            }
        }
        .listStyle(.bordered(alternatesRowBackgrounds: true))
    }
}
