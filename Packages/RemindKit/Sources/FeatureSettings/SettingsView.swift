import AppKit
import DesignSystem
import Speech
import SwiftUI
import UniformTypeIdentifiers

/// Settings, using the system's tabbed window and right-aligned form layout.
public struct SettingsView: View {
    @Bindable private var model: SettingsModel
    private let actions: any SettingsActions
    private let shortcuts: AnyView

    public init(model: SettingsModel, actions: any SettingsActions, shortcuts: AnyView) {
        self.model = model
        self.actions = actions
        self.shortcuts = shortcuts
    }

    public var body: some View {
        TabView {
            GeneralTab(model: model, actions: actions)
                .tabItem { Label("General", systemImage: "gearshape") }
            ScreenTab(model: model, actions: actions)
                .tabItem { Label("Screen", systemImage: "display") }
            AudioTab(model: model)
                .tabItem { Label("Audio", systemImage: "waveform") }
            MeetingsTab(model: model)
                .tabItem { Label("Meetings", systemImage: "calendar") }
            StorageTab(model: model, actions: actions)
                .tabItem { Label("Storage", systemImage: "internaldrive") }
            shortcuts
                .tabItem { Label("Shortcuts", systemImage: "keyboard") }
        }
        .frame(width: 640)
        .tint(Palette.verdigris)
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
            Toggle("Show in Dock", isOn: $model.showInDock)
            Toggle("Check for updates automatically", isOn: $model.checkForUpdates)
        }
        .formStyle(.columns)
        .padding(28)
    }
}

private struct ScreenTab: View {
    @Bindable var model: SettingsModel
    let actions: any SettingsActions
    @State private var showRunningOnly = false

    var body: some View {
        Form {
            Section {
                Text("Screen recordings stay on this Mac. They're never uploaded.")
                    .font(.headline)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.bottom, 10)
            }
            LabeledContent("Exclude apps:") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Windows from these apps are left out of recordings.")
                        .foregroundStyle(.secondary)
                    AppExclusionList(
                        choices: actions.runningApps,
                        excluded: $model.excludedApps
                    )
                    .frame(height: 210)
                    Button {
                        addApp()
                    } label: {
                        Image(systemName: "plus").frame(width: 22)
                    }
                    .help("Choose an app to exclude")
                }
            }
            LabeledContent("Private browsing:") {
                Toggle(isOn: $model.excludePrivateWindows) {
                    Text("Don't record private or incognito browser windows")
                }
                .toggleStyle(.checkbox)
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
        .padding(28)
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

private struct AppExclusionList: View {
    let choices: [AppChoice]
    @Binding var excluded: Set<String>

    /// Every running app, plus excluded ones that aren't running now.
    private var rows: [AppChoice] {
        var all = choices
        let known = Set(choices.map(\.bundleID))
        for id in excluded.subtracting(known) {
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
        }
    }
}

private struct MeetingsTab: View {
    @Bindable var model: SettingsModel

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
