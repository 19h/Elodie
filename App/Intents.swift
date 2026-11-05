import AppIntents
import AppKit
import Foundation

/// Opens search, for Shortcuts and Siri.
struct SearchRemindIntent: AppIntent {
    static let title: LocalizedStringResource = "Search Remind"
    static let description = IntentDescription("Opens Remind's search.")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        AppController.shared?.showSearch()
        return .result()
    }
}

/// Opens the timeline at a moment.
struct JumpToMomentIntent: AppIntent {
    static let title: LocalizedStringResource = "Go to a moment in Remind"
    static let description = IntentDescription("Opens Remind's timeline at a date and time.")
    static let openAppWhenRun = true

    @Parameter(title: "Date and time")
    var moment: Date

    @MainActor
    func perform() async throws -> some IntentResult {
        AppController.shared?.showMoment(at: moment)
        return .result()
    }
}

/// Pauses recording, with an optional time limit.
struct PauseRecordingIntent: AppIntent {
    static let title: LocalizedStringResource = "Pause Remind recording"
    static let description = IntentDescription("Pauses Remind's screen recording.")
    static let openAppWhenRun = false

    @Parameter(title: "Minutes", description: "Leave empty to pause until you resume.")
    var minutes: Int?

    @MainActor
    func perform() async throws -> some IntentResult {
        AppController.shared?.setPaused(true, for: minutes.map { TimeInterval($0) * 60 })
        return .result()
    }
}

struct ResumeRecordingIntent: AppIntent {
    static let title: LocalizedStringResource = "Resume Remind recording"
    static let description = IntentDescription("Resumes Remind's screen recording.")
    static let openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult {
        AppController.shared?.setPaused(false)
        return .result()
    }
}

struct RemindShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: SearchRemindIntent(),
            phrases: ["Search \(.applicationName)"],
            shortTitle: "Search",
            systemImageName: "magnifyingglass"
        )
        AppShortcut(
            intent: PauseRecordingIntent(),
            phrases: ["Pause \(.applicationName)"],
            shortTitle: "Pause",
            systemImageName: "pause.circle"
        )
        AppShortcut(
            intent: ResumeRecordingIntent(),
            phrases: ["Resume \(.applicationName)"],
            shortTitle: "Resume",
            systemImageName: "record.circle"
        )
    }
}
