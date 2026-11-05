import AppIntents
import CoreFoundation
import SwiftUI
import WidgetKit

/// Asks the app to pause or resume. This extension runs in its own sandbox, so it sends
/// a notification with no data in it, which is all it needs.
struct ToggleRecordingIntent: AppIntent {
    static let title: LocalizedStringResource = "Pause or resume Remind"
    static let description = IntentDescription("Pauses Remind's recording, or resumes it if it's paused.")

    func perform() async throws -> some IntentResult {
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName("app.remind.toggle-recording" as CFString),
            nil,
            nil,
            true
        )
        return .result()
    }
}

/// A button for Control Center and the menu bar.
struct RecordingControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "app.remind.recording") {
            ControlWidgetButton(action: ToggleRecordingIntent()) {
                Label("Pause or resume", systemImage: "pause.circle")
            }
        }
        .displayName("Remind recording")
        .description("Pauses or resumes Remind's recording.")
    }
}

@main
struct RemindWidgets: WidgetBundle {
    var body: some Widget {
        RecordingControl()
    }
}
