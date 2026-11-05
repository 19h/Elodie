import AVFoundation
import Capture
import CoreAPI
import CoreMedia
import Foundation
@preconcurrency import ScreenCaptureKit

/// Which audio to record.
public struct AudioSources: Sendable, Equatable {
    public var microphone: Bool
    public var speakers: Bool

    public init(microphone: Bool, speakers: Bool) {
        self.microphone = microphone
        self.speakers = speakers
    }
}

/// Records and transcribes what's said. Audio is never written to disk: only the
/// transcript is kept.
///
/// Speaker audio and the microphone stay on separate tracks, so the transcript knows who
/// said what, and an echo can be removed afterward without muting anyone.
public final class AudioRecorder: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let core: any RemindCore
    private let queue = DispatchQueue(label: "remind.audio", qos: .utility)
    private var stream: SCStream?
    private var microphone: Transcriber?
    private var speakers: Transcriber?
    private var title: String?
    private let lock = NSLock()
    private var pending: [SpokenWord] = []
    private var flushTask: Task<Void, Never>?

    /// How long to gather words before storing them. Echo removal needs both tracks'
    /// words for the same moment to arrive together.
    private static let flushInterval: Duration = .seconds(15)

    public init(core: any RemindCore) {
        self.core = core
    }

    public func start(sources: AudioSources, locale: Locale, title: String?) async throws {
        self.title = title
        let language = try await Transcriber.prepare(locale: locale)
        let started = Date()

        let collect: @Sendable ([SpokenWord]) -> Void = { [weak self] words in
            self?.collect(words)
        }
        if sources.microphone {
            let transcriber = Transcriber(locale: language, isMe: true, startedAt: started, onWords: collect)
            try await transcriber.start()
            microphone = transcriber
        }
        if sources.speakers {
            let transcriber = Transcriber(locale: language, isMe: false, startedAt: started, onWords: collect)
            try await transcriber.start()
            speakers = transcriber
        }

        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first else {
            throw DisplayStreamError.displayNotFound(0)
        }
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let configuration = SCStreamConfiguration()
        // There's no use for its video, so this is the smallest and slowest allowed.
        configuration.width = 2
        configuration.height = 2
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        configuration.capturesAudio = sources.speakers
        configuration.captureMicrophone = sources.microphone
        configuration.excludesCurrentProcessAudio = true
        configuration.sampleRate = 16_000
        configuration.channelCount = 1

        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        if sources.speakers {
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        }
        if sources.microphone {
            try stream.addStreamOutput(self, type: .microphone, sampleHandlerQueue: queue)
        }
        try await stream.startCapture()
        self.stream = stream

        flushTask = Task.detached(priority: .utility) { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.flushInterval)
                self?.flush()
            }
        }
    }

    public func stop() async {
        flushTask?.cancel()
        flushTask = nil
        let stream = self.stream
        self.stream = nil
        try? await stream?.stopCapture()
        try? await microphone?.finish()
        try? await speakers?.finish()
        microphone = nil
        speakers = nil
        flush()
    }

    private func collect(_ words: [SpokenWord]) {
        lock.withLock { pending.append(contentsOf: words) }
    }

    private func flush() {
        let words = lock.withLock { () -> [SpokenWord] in
            defer { pending.removeAll() }
            return pending
        }
        guard !words.isEmpty else { return }
        try? core.appendTranscript(words, title: title)
    }

    public func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard sampleBuffer.isValid, let buffer = Self.pcmBuffer(from: sampleBuffer) else { return }
        switch type {
        case .audio: speakers?.append(buffer, at: Date())
        case .microphone: microphone?.append(buffer, at: Date())
        default: break
        }
    }

    public func stream(_ stream: SCStream, didStopWithError error: any Error) {
        Task { await self.stop() }
    }

    private static func pcmBuffer(from sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let description = sampleBuffer.formatDescription?.audioStreamBasicDescription else { return nil }
        var asbd = description
        guard let format = AVAudioFormat(streamDescription: &asbd) else { return nil }
        let frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return nil }
        buffer.frameLength = frames
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer, at: 0, frameCount: Int32(frames), into: buffer.mutableAudioBufferList
        )
        return status == noErr ? buffer : nil
    }
}
