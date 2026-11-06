import AppIntents
import SwiftUI
import WidgetKit

/// Asks the app to pause or resume. The button can only ask, so it shows what the app reports
/// back rather than what was asked for.
struct SetRecordingIntent: SetValueIntent {
    static let title: LocalizedStringResource = "Turn Elodie's recording on or off"
    static let description = IntentDescription("Pauses Elodie's recording, or resumes it if it's paused.")

    @Parameter(title: "Recording")
    var value: Bool

    func perform() async throws -> some IntentResult {
        RecordingChannel.request(recording: value)
        return .result()
    }
}

struct RecordingValue: ControlValueProvider {
    var previewValue: Bool { true }

    func currentValue() async throws -> Bool {
        RecordingChannel.state == .recording
    }
}

/// A switch for Control Center and the menu bar, showing whether Elodie is recording.
struct RecordingControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: RecordingChannel.controlKind, provider: RecordingValue()) { isRecording in
            ControlWidgetToggle("Elodie", isOn: isRecording, action: SetRecordingIntent()) { isOn in
                Label(
                    isOn ? "Recording" : "Not recording",
                    systemImage: isOn ? "record.circle" : "pause.circle"
                )
            }
            .tint(Color(red: 0.27, green: 0.79, blue: 0.69))
        }
        .displayName("Elodie recording")
        .description("Shows whether Elodie is recording, and pauses or resumes it.")
    }
}

@main
struct ElodieWidgets: WidgetBundle {
    var body: some Widget {
        RecordingControl()
    }
}
