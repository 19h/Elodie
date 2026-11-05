import CoreAudio
import Foundation

/// A call that seems to be happening.
public struct DetectedMeeting: Equatable, Sendable {
    public var app: String
    public var title: String?
    /// It was recognised from a browser's address, which can only be read while that tab is
    /// in front.
    public var isInBrowser: Bool

    public init(app: String, title: String?, isInBrowser: Bool = false) {
        self.app = app
        self.title = title
        self.isInBrowser = isInBrowser
    }
}

/// What's on screen and in use right now, for deciding whether a meeting is on.
public struct MeetingSignals: Sendable {
    public struct Window: Sendable {
        public var bundleID: String?
        public var title: String?
        public var url: String?

        public init(bundleID: String?, title: String?, url: String? = nil) {
            self.bundleID = bundleID
            self.title = title
            self.url = url
        }
    }

    public var windows: [Window]
    public var isMicrophoneInUse: Bool

    public init(windows: [Window], isMicrophoneInUse: Bool) {
        self.windows = windows
        self.isMicrophoneInUse = isMicrophoneInUse
    }
}

/// Recognises calls from window titles and URLs.
public enum MeetingDetector {
    /// Whether a meeting is on. Each app has its own tell. Browser tabs and apps whose
    /// windows look the same in or out of a call also need the microphone to be in use,
    /// or leaving a meeting tab open would count as still being in the meeting.
    public static func detect(_ signals: MeetingSignals) -> DetectedMeeting? {
        for window in signals.windows {
            let title = window.title ?? ""
            switch window.bundleID {
            case "us.zoom.xos":
                if title.contains("Zoom Meeting") || title.contains("Zoom Webinar") {
                    return DetectedMeeting(app: "Zoom", title: nil)
                }
            case "com.tinyspeck.slackmacgap":
                if title.localizedCaseInsensitiveContains("huddle"), signals.isMicrophoneInUse {
                    return DetectedMeeting(app: "Slack", title: nil)
                }
            case "com.webex.meetingmanager":
                if signals.isMicrophoneInUse {
                    return DetectedMeeting(app: "Webex", title: nil)
                }
            case "com.microsoft.teams2", "com.microsoft.teams":
                if signals.isMicrophoneInUse, title.contains("|") {
                    return DetectedMeeting(app: "Microsoft Teams", title: nil)
                }
            default:
                if let url = window.url, signals.isMicrophoneInUse, let service = webService(for: url) {
                    return DetectedMeeting(app: service, title: nil, isInBrowser: true)
                }
            }
        }
        return nil
    }

    private static func webService(for url: String) -> String? {
        let lowered = url.lowercased()
        if lowered.contains("meet.google.com/"), !lowered.hasSuffix("meet.google.com/") {
            return "Google Meet"
        }
        if lowered.contains("zoom.us/wc/") || lowered.contains("zoom.us/j/") {
            return "Zoom"
        }
        if lowered.contains("teams.microsoft.com") || lowered.contains("teams.live.com") {
            return "Microsoft Teams"
        }
        return nil
    }

    /// Whether anything on this Mac is using the default microphone.
    public static var isMicrophoneInUse: Bool {
        var device = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device
        ) == noErr, device != kAudioObjectUnknown else {
            return false
        }
        var running: UInt32 = 0
        size = UInt32(MemoryLayout<UInt32>.size)
        address.mSelector = kAudioDevicePropertyDeviceIsRunningSomewhere
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &running) == noErr else {
            return false
        }
        return running != 0
    }
}
