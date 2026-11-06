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
    private let core: any ElodieCore
    private let queue = DispatchQueue(label: "elodie.audio", qos: .utility)
    private var stream: SCStream?
    private var microphone: Transcriber?
    private var speakers: Transcriber?
    private var title: String?
    private let lock = NSLock()
    private var pending: [SpokenWord] = []
    private var flushTask: Task<Void, Never>?
    /// Anything said up to this moment has been deleted, so it isn't stored if it arrives late.
    private var discardBefore = Date.distantPast
    /// Bumped by stopping, so a start that's still in progress knows not to carry on.
    private var generation = 0
    private var lastChange: Task<Void, any Error>?

    /// Called when audio stops by itself, with the reason in words.
    public var onFailure: (@Sendable (String) -> Void)?

    /// How long to gather words before storing them. Echo removal needs both tracks'
    /// words for the same moment to arrive together.
    private static let flushInterval: Duration = .seconds(15)

    public init(core: any ElodieCore) {
        self.core = core
    }

    /// Starts listening. Starting and stopping happen one at a time and in the order asked
    /// for, so stopping during the long first-use download really does stop it.
    ///
    /// - Parameter excluding: apps whose sound stays out of the transcript, as their windows
    ///   stay out of recordings.
    public func start(
        sources: AudioSources,
        locale: Locale,
        title: String?,
        excluding excludedBundleIDs: Set<String> = []
    ) async throws {
        let token = lock.withLock { generation }
        try await enqueue { recorder in
            try await recorder.performStart(
                sources: sources,
                locale: locale,
                title: title,
                excluding: excludedBundleIDs,
                token: token
            )
        }.value
    }

    public func stop() async {
        lock.withLock { generation += 1 }
        _ = await enqueue { recorder in
            await recorder.performStop()
        }.result
    }

    /// Drops words that haven't been stored yet from up to this moment, and any that arrive
    /// late, because that stretch has just been deleted.
    public func forget(through time: Date) {
        let cutoffDate = time
        lock.withLock {
            discardBefore = max(discardBefore, cutoffDate)
            pending.removeAll { $0.time <= cutoffDate }
        }
    }

    private func enqueue(
        _ work: @escaping @Sendable (AudioRecorder) async throws -> Void
    ) -> Task<Void, any Error> {
        lock.withLock {
            let previous = lastChange
            let task = Task<Void, any Error> { [self] in
                _ = await previous?.result
                try await work(self)
            }
            lastChange = task
            return task
        }
    }

    private func checkStillWanted(_ token: Int) throws {
        if lock.withLock({ generation }) != token {
            throw CancellationError()
        }
    }

    private func performStart(
        sources: AudioSources,
        locale: Locale,
        title: String?,
        excluding excludedBundleIDs: Set<String>,
        token: Int
    ) async throws {
        try checkStillWanted(token)
        self.title = title
        let language = try await Transcriber.prepare(locale: locale)
        try checkStillWanted(token)
        let started = Date()

        do {
            let collect: @Sendable ([SpokenWord]) -> Void = { [weak self] words in
                self?.collect(words)
            }
            let failed: @Sendable (any Error) -> Void = { [weak self] error in
                self?.speechFailed(error)
            }
            if sources.microphone {
                let transcriber = Transcriber(locale: language, isMe: true, startedAt: started, onWords: collect, onFailure: failed)
                try await transcriber.start()
                microphone = transcriber
            }
            if sources.speakers {
                let transcriber = Transcriber(locale: language, isMe: false, startedAt: started, onWords: collect, onFailure: failed)
                try await transcriber.start()
                speakers = transcriber
            }

            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let display = content.displays.first else {
                throw DisplayCaptureError.displayNotFound(0)
            }
            let excludedApps = content.applications.filter { excludedBundleIDs.contains($0.bundleIdentifier) }
            let filter = SCContentFilter(display: display, excludingApplications: excludedApps, exceptingWindows: [])
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
            try checkStillWanted(token)
            try await stream.startCapture()
            self.stream = stream
            try checkStillWanted(token)
        } catch {
            // A partial start mustn't leave anything listening.
            await performStop()
            throw error
        }

        flushTask = Task.detached(priority: .utility) { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.flushInterval)
                self?.flush()
            }
        }
    }

    private func performStop() async {
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
        lock.withLock {
            pending.append(contentsOf: words.filter { $0.time > discardBefore })
        }
    }

    private func flush() {
        let words = lock.withLock { () -> [SpokenWord] in
            defer { pending.removeAll() }
            return pending
        }
        guard !words.isEmpty else { return }
        do {
            try core.appendTranscript(words, title: title)
        } catch {
            // They aren't lost yet, and the next flush tries them again.
            lock.withLock { pending.insert(contentsOf: words, at: 0) }
        }
    }

    public func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard sampleBuffer.isValid, let buffer = Self.pcmBuffer(from: sampleBuffer) else { return }
        #if DEBUG
        if type == .microphone { noteMicrophone(buffer) }
        #endif
        switch type {
        case .audio: speakers?.append(buffer, at: Date())
        case .microphone: microphone?.append(buffer, at: Date())
        default: break
        }
    }

    public func stream(_ stream: SCStream, didStopWithError error: any Error) {
        lock.withLock { generation += 1 }
        _ = enqueue { recorder in
            await recorder.performStop()
        }
        onFailure?(String(localized: "Audio capture stopped: \(error.localizedDescription)"))
    }

    #if DEBUG
    private var microphoneBuffers = 0
    private var microphonePeak: Float = 0
    private var microphoneFormat = "none"

    /// What's arrived from the microphone and how much reached speech recognition, for
    /// checking a real run.
    public var debugMicrophone: String {
        let fed = microphone?.debugFed
        return lock.withLock {
            "\(microphoneBuffers) buffers, peak \(microphonePeak), format \(microphoneFormat), recognition got \(fed?.frames ?? 0) frames at \(fed?.format ?? "none"), peak \(fed?.peak ?? 0)"
        }
    }

    private func noteMicrophone(_ buffer: AVAudioPCMBuffer) {
        guard let samples = buffer.floatChannelData?[0] else { return }
        var peak: Float = 0
        for index in 0..<Int(buffer.frameLength) { peak = max(peak, abs(samples[index])) }
        lock.withLock {
            microphoneBuffers += 1
            microphonePeak = max(microphonePeak, peak)
            microphoneFormat = "\(buffer.format)"
        }
    }
    #endif

    private func speechFailed(_ error: any Error) {
        onFailure?(String(localized: "Transcription stopped working: \(error.localizedDescription)"))
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
