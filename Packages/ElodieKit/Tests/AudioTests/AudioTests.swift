@testable import Audio
import AVFoundation
import CoreAPI
import CoreLive
import Foundation
import Testing

@Suite struct DetectingMeetings {
    private func detect(
        _ bundleID: String?,
        title: String? = nil,
        url: String? = nil,
        microphone: Bool = true
    ) -> DetectedMeeting? {
        MeetingDetector.detect(MeetingSignals(
            windows: [.init(bundleID: bundleID, title: title, url: url)],
            isMicrophoneInUse: microphone
        ))
    }

    @Test func zoomIsRecognisedFromItsMeetingWindow() {
        #expect(detect("us.zoom.xos", title: "Zoom Meeting")?.app == "Zoom")
        #expect(detect("us.zoom.xos", title: "Zoom Workplace") == nil)
    }

    @Test func slackNeedsAHuddleAndTheMicrophone() {
        #expect(detect("com.tinyspeck.slackmacgap", title: "Huddle: #design")?.app == "Slack")
        #expect(detect("com.tinyspeck.slackmacgap", title: "Huddle: #design", microphone: false) == nil)
        #expect(detect("com.tinyspeck.slackmacgap", title: "#design") == nil)
    }

    /// Leaving a meeting tab open after the call isn't a meeting.
    /// A call in a tab can only be seen while the tab is in front, so the app has to know it
    /// came from a browser in order to keep it going after someone switches away.
    @Test func browserMeetingsSayTheyAreInABrowser() {
        let meeting = MeetingDetector.detect(MeetingSignals(
            windows: [.init(bundleID: "com.google.Chrome", title: "Meet", url: "https://meet.google.com/abc-defg-hij")],
            isMicrophoneInUse: true
        ))
        #expect(meeting?.isInBrowser == true)
        let zoom = MeetingDetector.detect(MeetingSignals(
            windows: [.init(bundleID: "us.zoom.xos", title: "Zoom Meeting")],
            isMicrophoneInUse: true
        ))
        #expect(zoom?.isInBrowser == false)
    }

    @Test func browserMeetingsNeedTheMicrophone() {
        let url = "https://meet.google.com/abc-defg-hij"
        #expect(detect("com.google.Chrome", url: url)?.app == "Google Meet")
        #expect(detect("com.google.Chrome", url: url, microphone: false) == nil)
    }

    @Test func aMeetingServicesHomePageIsNotAMeeting() {
        #expect(detect("com.google.Chrome", url: "https://meet.google.com/") == nil)
        #expect(detect("com.google.Chrome", url: "https://zoom.us/pricing") == nil)
    }

    @Test func zoomInABrowserIsRecognised() {
        #expect(detect("com.apple.Safari", url: "https://acme.zoom.us/j/123456")?.app == "Zoom")
    }

    @Test func anyOtherWindowWithTheMicrophoneOnIsNotAMeeting() {
        #expect(detect("com.example.notes", title: "Zoom Meeting notes") == nil)
    }

    @Test func checkingTheMicrophoneDoesNotCrash() {
        _ = MeetingDetector.isMicrophoneInUse
    }
}

/// Real speech recognition on real audio, with no microphone: `say` speaks known text
/// to a file, and the transcriber has to get it back with real timing.
@Suite struct PlacingLiveAudio {
    private let rate = 16_000.0

    @Test func audioThatSeemsToStartEarlyFollowsOnFromTheLast() {
        // The last buffer ended at 1 second, and this one claims 0.9.
        #expect(Transcriber.position(forArrivalAt: 0.9, next: 16_000, sampleRate: rate) == 16_000)
    }

    @Test func smallDelaysAreJustUnevenArrival() {
        #expect(Transcriber.position(forArrivalAt: 1.3, next: 16_000, sampleRate: rate) == 16_000)
    }

    /// Nothing plays for a while, so nothing's delivered, and times have to pick up from now.
    @Test func aRealGapMovesForward() {
        #expect(Transcriber.position(forArrivalAt: 5, next: 16_000, sampleRate: rate) == 80_000)
    }
}

@Suite struct RealSpeech {
    private final class Words: @unchecked Sendable {
        let lock = NSLock()
        var all: [SpokenWord] = []
    }

    private func speak(_ text: String, to url: URL, format: String = "LEI16@16000") throws {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/say")
        process.arguments = ["-v", "Samantha", "-o", url.path, "--data-format=\(format)", text]
        try process.run()
        process.waitUntilExit()
        try #require(process.terminationStatus == 0)
    }

    private func transcribe(_ sentence: String) async throws -> [SpokenWord] {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "elodie-audio-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "speech.wav")
        try speak(sentence, to: file)

        let collected = Words()
        let locale = try await Transcriber.prepare(locale: Locale(identifier: "en_US"))
        let transcriber = Transcriber(locale: locale, isMe: false, startedAt: Date(timeIntervalSince1970: 1_800_000_000)) { words in
            collected.lock.withLock { collected.all.append(contentsOf: words) }
        }
        try await transcriber.transcribe(file: file)
        return collected.lock.withLock { collected.all }
    }

    /// Live audio arrives in uneven bursts, timed only by when each one turned up. The analyzer
    /// refuses a buffer that seems to start before the last ended, which stopped transcription
    /// within seconds on real system audio.
    @Test func unevenLiveBuffersStillTranscribe() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "elodie-audio-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "speech.wav")
        try speak("The quarterly budget review is scheduled for next Tuesday morning.", to: file)

        let collected = Words()
        let failures = Words()
        let started = Date(timeIntervalSince1970: 1_800_000_000)
        let locale = try await Transcriber.prepare(locale: Locale(identifier: "en_US"))
        let transcriber = Transcriber(
            locale: locale,
            isMe: false,
            startedAt: started,
            onWords: { words in collected.lock.withLock { collected.all.append(contentsOf: words) } },
            onFailure: { _ in failures.lock.withLock { failures.all.append(SpokenWord(text: "failed", time: started, duration: 0, confidence: 0, isMe: false)) } }
        )
        try await transcriber.start()

        let audio = try AVAudioFile(forReading: file)
        let chunk = AVAudioFrameCount(audio.processingFormat.sampleRate / 10)
        var position = 0.0
        var index = 0
        while audio.framePosition < audio.length {
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: audio.processingFormat, frameCapacity: chunk))
            try audio.read(into: buffer, frameCount: chunk)
            // Every other buffer turns up early enough to overlap the one before it.
            let jitter = index % 2 == 0 ? -0.06 : 0.04
            transcriber.append(buffer, at: started.addingTimeInterval(max(0, position + jitter)))
            position += Double(buffer.frameLength) / audio.processingFormat.sampleRate
            index += 1
        }
        try await transcriber.finish()

        #expect(failures.lock.withLock { failures.all.isEmpty })
        let text = collected.lock.withLock { collected.all }.map { $0.text.lowercased() }.joined(separator: " ")
        #expect(text.contains("budget"), "got: \(text)")
        #expect(text.contains("tuesday"), "got: \(text)")
    }

    /// What a real microphone delivers on this Mac, measured in a real run: 44.1 kHz mono
    /// float, in buffers of about 540 frames, whatever rate was asked for. Speech in exactly
    /// that shape has to become words, and they have to count as the person's own.
    @Test func speechInTheMicrophonesRealFormatBecomesYourWords() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "elodie-audio-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "speech.wav")
        try speak("The quarterly budget review is scheduled for next Tuesday morning.", to: file, format: "LEF32@44100")

        let collected = Words()
        let started = Date(timeIntervalSince1970: 1_800_000_000)
        let locale = try await Transcriber.prepare(locale: Locale(identifier: "en_US"))
        let transcriber = Transcriber(locale: locale, isMe: true, startedAt: started) { words in
            collected.lock.withLock { collected.all.append(contentsOf: words) }
        }
        try await transcriber.start()

        let audio = try AVAudioFile(forReading: file)
        #expect(audio.processingFormat.sampleRate == 44_100)
        #expect(audio.processingFormat.commonFormat == .pcmFormatFloat32)
        var position = 0.0
        while audio.framePosition < audio.length {
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: audio.processingFormat, frameCapacity: 540))
            try audio.read(into: buffer, frameCount: 540)
            transcriber.append(buffer, at: started.addingTimeInterval(position))
            position += Double(buffer.frameLength) / 44_100
        }
        try await transcriber.finish()

        let words = collected.lock.withLock { collected.all }
        let text = words.map { $0.text.lowercased() }.joined(separator: " ")
        #expect(text.contains("budget"), "got: \(text)")
        #expect(text.contains("tuesday"), "got: \(text)")
        #expect(!words.isEmpty && words.allSatisfy(\.isMe))
        // Conversion mustn't stretch time: it took about as long as it was said.
        #expect(abs((words.last?.time.timeIntervalSince(started) ?? 0) - position) < 2)
    }

    @Test func spokenWordsComeBackWithRealTimesAndConfidence() async throws {
        let words = try await transcribe(
            "The quarterly budget review is scheduled for next Tuesday morning at the main office."
        )
        let text = words.map { $0.text.lowercased() }.joined(separator: " ")
        #expect(text.contains("quarterly"), "got: \(text)")
        #expect(text.contains("budget"), "got: \(text)")
        #expect(text.contains("tuesday"), "got: \(text)")

        // The fake data the reference app used would fail each of these.
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let times = words.map { $0.time.timeIntervalSince(start) }
        #expect(times == times.sorted(), "times should only go forward")
        #expect((times.last ?? 0) > 2, "a sentence this long takes more than 2 seconds to say")
        #expect(words.allSatisfy { $0.duration > 0 })
        let confidences = Set(words.map(\.confidence))
        #expect(confidences.count > 1, "real confidence varies, unlike a fixed 1.0")
        #expect(confidences.allSatisfy { (0...1).contains($0) })
    }

    @Test func spokenWordsBecomeSearchableThroughTheRealCore() async throws {
        let words = try await transcribe("Please remember the zebra project deadline.")
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "elodie-audio-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let core = try LiveCore(vaultDirectory: directory, masterKey: Data(repeating: 4, count: 32))

        try core.appendTranscript(words, title: "Planning call")
        let session = try #require(try core.search("deadline ", facets: SearchFacets(transcriptsOnly: true), order: .newest))
        let page = try session.nextPage()
        let hit = try #require(page.hits.first)
        #expect(hit.isTranscript)
        #expect(hit.snippet.lowercased().contains("deadline"))
        #expect(hit.window == "Planning call")
    }
}
