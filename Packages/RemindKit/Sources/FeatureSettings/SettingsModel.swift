import Foundation
import Observation

/// How long recordings are kept.
public enum RetentionPeriod: String, CaseIterable, Identifiable, Sendable {
    case oneWeek, oneMonth, threeMonths, sixMonths, oneYear, forever

    public var id: String { rawValue }

    public var title: LocalizedStringResource {
        switch self {
        case .oneWeek: "1 week"
        case .oneMonth: "1 month"
        case .threeMonths: "3 months"
        case .sixMonths: "6 months"
        case .oneYear: "1 year"
        case .forever: "Forever"
        }
    }

    /// The oldest moment to keep. Whole days, so deletion doesn't cut a day in half.
    public func cutoff(now: Date, calendar: Calendar = .current) -> Date? {
        let start = calendar.startOfDay(for: now)
        return switch self {
        case .oneWeek: calendar.date(byAdding: .day, value: -7, to: start)
        case .oneMonth: calendar.date(byAdding: .month, value: -1, to: start)
        case .threeMonths: calendar.date(byAdding: .month, value: -3, to: start)
        case .sixMonths: calendar.date(byAdding: .month, value: -6, to: start)
        case .oneYear: calendar.date(byAdding: .year, value: -1, to: start)
        case .forever: nil
        }
    }
}

public enum TextRecognitionMode: String, CaseIterable, Identifiable, Sendable {
    case standard, additionalLanguages

    public var id: String { rawValue }
}

public enum AudioSource: String, CaseIterable, Identifiable, Sendable {
    case microphoneAndSpeaker, microphoneOnly, speakerOnly

    public var id: String { rawValue }
}

public enum MeetingDetectedChoice: String, CaseIterable, Identifiable, Sendable {
    case ask, recordAutomatically, doNotRecord

    public var id: String { rawValue }
}

/// The user's settings, saved as they change.
@MainActor
@Observable
public final class SettingsModel {
    private let defaults: UserDefaults

    public var showInDock: Bool { didSet { defaults.set(showInDock, forKey: "showInDock") } }
    public var remindWhenPaused: Bool { didSet { defaults.set(remindWhenPaused, forKey: "remindWhenPaused") } }
    public var checkForUpdates: Bool { didSet { defaults.set(checkForUpdates, forKey: "checkForUpdates") } }
    public var excludedApps: Set<String> {
        didSet { defaults.set(Array(excludedApps).sorted(), forKey: "excludedApps") }
    }
    public var excludePrivateWindows: Bool {
        didSet { defaults.set(excludePrivateWindows, forKey: "excludePrivateWindows") }
    }
    public var textRecognition: TextRecognitionMode {
        didSet { defaults.set(textRecognition.rawValue, forKey: "textRecognition") }
    }
    public var transcriptionLanguage: String {
        didSet { defaults.set(transcriptionLanguage, forKey: "transcriptionLanguage") }
    }
    public var audioSource: AudioSource {
        didSet { defaults.set(audioSource.rawValue, forKey: "audioSource") }
    }
    public var meetingDetected: MeetingDetectedChoice {
        didSet { defaults.set(meetingDetected.rawValue, forKey: "meetingDetected") }
    }
    public var retention: RetentionPeriod {
        didSet { defaults.set(retention.rawValue, forKey: "retention") }
    }
    public var hasFinishedOnboarding: Bool {
        didSet { defaults.set(hasFinishedOnboarding, forKey: "hasFinishedOnboarding") }
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        func bool(_ key: String, _ fallback: Bool) -> Bool {
            defaults.object(forKey: key) as? Bool ?? fallback
        }
        showInDock = bool("showInDock", false)
        remindWhenPaused = bool("remindWhenPaused", true)
        checkForUpdates = bool("checkForUpdates", true)
        excludedApps = Set(defaults.stringArray(forKey: "excludedApps") ?? [])
        // On in every language. Private windows shouldn't depend on system language.
        excludePrivateWindows = bool("excludePrivateWindows", true)
        textRecognition = defaults.string(forKey: "textRecognition").flatMap(TextRecognitionMode.init) ?? .standard
        transcriptionLanguage = defaults.string(forKey: "transcriptionLanguage") ?? Locale.current.identifier
        audioSource = defaults.string(forKey: "audioSource").flatMap(AudioSource.init) ?? .microphoneAndSpeaker
        // Recording someone else is a decision to make each time.
        meetingDetected = defaults.string(forKey: "meetingDetected").flatMap(MeetingDetectedChoice.init) ?? .ask
        retention = defaults.string(forKey: "retention").flatMap(RetentionPeriod.init) ?? .forever
        hasFinishedOnboarding = bool("hasFinishedOnboarding", false)
    }
}

/// What the Storage tab shows.
public struct StorageUsage: Sendable, Equatable {
    public var recordingBytes: Int64
    public var freeBytes: Int64
    public var oldest: Date?

    public init(recordingBytes: Int64, freeBytes: Int64, oldest: Date?) {
        self.recordingBytes = recordingBytes
        self.freeBytes = freeBytes
        self.oldest = oldest
    }

    /// An estimate from real usage, once there's enough history to base it on.
    public func bytesPerDay(now: Date) -> Int64? {
        guard let oldest else { return nil }
        let days = now.timeIntervalSince(oldest) / 86_400
        guard days >= 1 else { return nil }
        return Int64(Double(recordingBytes) / days)
    }
}

/// What the settings tabs ask the rest of the app to do.
@MainActor
public protocol SettingsActions: AnyObject {
    func storageUsage() async -> StorageUsage
    func deleteAllData() async
    func deleteRange(_ interval: DateInterval) async
    func applyRetention(_ period: RetentionPeriod) async
    func saveRecoveryKey()
    func revealVault()
    func setLaunchAtLogin(_ enabled: Bool)
    var launchAtLogin: Bool { get }
    var runningApps: [AppChoice] { get }
}

/// An app that can be excluded from recording.
public struct AppChoice: Identifiable, Sendable, Hashable {
    public var bundleID: String
    public var name: String
    public var path: String
    public var id: String { bundleID }

    public init(bundleID: String, name: String, path: String) {
        self.bundleID = bundleID
        self.name = name
        self.path = path
    }
}
