import Foundation
import notify

/// How the app and its Control Center button talk. The button runs in its own sandbox, so they
/// share nothing but system notifications: a name to post to say what's wanted, and a number
/// attached to another name to say what's true. The system forgets the number when the app
/// stops holding the name, so a crash can't leave the button claiming it's recording.
enum RecordingChannel {
    /// The control's identity, for asking the system to read it again.
    static let controlKind = "com.kenansulayman.elodie.recording"
    static let pauseRequest = "com.kenansulayman.elodie.pause-recording"
    static let resumeRequest = "com.kenansulayman.elodie.resume-recording"
    private static let stateName = "com.kenansulayman.elodie.recording-state"

    enum State: UInt64 {
        case notRunning = 0
        case recording = 1
        case paused = 2
    }

    /// What the app last said. Anyone can read this.
    static var state: State {
        var token: Int32 = 0
        guard notify_register_check(stateName, &token) == NOTIFY_STATUS_OK else { return .notRunning }
        defer { notify_cancel(token) }
        var value: UInt64 = 0
        guard notify_get_state(token, &value) == NOTIFY_STATUS_OK else { return .notRunning }
        return State(rawValue: value) ?? .notRunning
    }

    /// Held for as long as the app runs, because that's what keeps the number alive.
    nonisolated(unsafe) private static var held: Int32?

    /// Says what's true now. For the app only.
    static func publish(_ state: State) {
        if held == nil {
            var token: Int32 = 0
            guard notify_register_check(stateName, &token) == NOTIFY_STATUS_OK else { return }
            held = token
        }
        if let held { notify_set_state(held, state.rawValue) }
    }

    /// Asks the app to pause or resume. For the button.
    static func request(recording: Bool) {
        notify_post(recording ? resumeRequest : pauseRequest)
    }
}
