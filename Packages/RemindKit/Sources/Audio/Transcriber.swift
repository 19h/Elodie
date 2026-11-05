import AVFoundation
import CoreAPI
import CoreMedia
import Foundation
import Speech

public enum TranscriberError: Error, Equatable {
    case languageNotSupported(String)
    case noAudioFormat
}

/// Turns audio into words with exact times, on this Mac.
///
/// The reference app ran Whisper and then guessed word times by spreading them evenly
/// across each segment, with confidence fixed at 1.0. The system's analyzer reports
/// real times and real confidence for each piece of text, and macOS keeps its models
/// up to date, so there's nothing to bundle.
public final class Transcriber: @unchecked Sendable {
    private let transcriber: SpeechTranscriber
    private let analyzer: SpeechAnalyzer
    private let isMe: Bool
    private let startedAt: Date
    private let onWords: @Sendable ([SpokenWord]) -> Void
    private let onFailure: @Sendable (any Error) -> Void
    private var isFinishing = false

    private var input: AsyncStream<AnalyzerInput>.Continuation?
    private var resultsTask: Task<Void, Never>?
    private var converter: AVAudioConverter?
    public private(set) var format: AVAudioFormat?

    /// - Parameters:
    ///   - isMe: whether this audio is the microphone rather than the computer's audio.
    ///   - startedAt: the moment that sample time zero corresponds to.
    public init(
        locale: Locale,
        isMe: Bool,
        startedAt: Date,
        onWords: @escaping @Sendable ([SpokenWord]) -> Void,
        onFailure: @escaping @Sendable (any Error) -> Void = { _ in }
    ) {
        self.onFailure = onFailure
        transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [],
            attributeOptions: [.audioTimeRange, .transcriptionConfidence]
        )
        analyzer = SpeechAnalyzer(modules: [transcriber])
        self.isMe = isMe
        self.startedAt = startedAt
        self.onWords = onWords
    }

    /// Whether this language can be transcribed on this Mac, downloading it if needed.
    /// macOS manages the download.
    public static func prepare(locale: Locale) async throws -> Locale {
        guard let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
            throw TranscriberError.languageNotSupported(locale.identifier)
        }
        let installed = await SpeechTranscriber.installedLocales
        if !installed.contains(where: { $0.identifier == supported.identifier }) {
            let module = SpeechTranscriber(locale: supported, preset: .transcription)
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
                try await request.downloadAndInstall()
            }
        }
        return supported
    }

    /// Starts listening for results and taking audio.
    public func start() async throws {
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw TranscriberError.noAudioFormat
        }
        self.format = format
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        input = continuation
        startReadingResults()
        try await analyzer.start(inputSequence: stream)
    }

    /// Adds audio, converting it to what the analyzer wants. It's stamped with where it
    /// falls in the stream, so times stay right even if a gap in audio is skipped.
    public func append(_ buffer: AVAudioPCMBuffer, at time: Date) {
        guard let format, let converted = convert(buffer, to: format) else { return }
        let offset = max(0, time.timeIntervalSince(startedAt))
        let start = CMTime(seconds: offset, preferredTimescale: CMTimeScale(format.sampleRate))
        input?.yield(AnalyzerInput(buffer: converted, bufferStartTime: start))
    }

    /// Finishes whatever's in progress, and waits for its results.
    public func finish() async throws {
        isFinishing = true
        input?.finish()
        input = nil
        try await analyzer.finalizeAndFinishThroughEndOfInput()
        await resultsTask?.value
    }

    /// Transcribes a whole audio file. Used by tests, which need real speech without a
    /// microphone.
    public func transcribe(file: URL) async throws {
        let audio = try AVAudioFile(forReading: file)
        startReadingResults()
        let last = try await analyzer.analyzeSequence(from: audio)
        if let last {
            try await analyzer.finalizeAndFinish(through: last)
        } else {
            await analyzer.cancelAndFinishNow()
        }
        await resultsTask?.value
    }

    private func startReadingResults() {
        let transcriber = self.transcriber
        let isMe = self.isMe
        let startedAt = self.startedAt
        let onWords = self.onWords
        resultsTask = Task.detached(priority: .utility) { [weak self] in
            do {
                for try await result in transcriber.results where result.isFinal {
                    let words = Self.words(from: result.text, isMe: isMe, startedAt: startedAt)
                    if !words.isEmpty { onWords(words) }
                }
            } catch {
                // What's been stored stays stored, but if this wasn't asked to finish then
                // transcription has stopped working, and someone should know.
                if let self, !self.isFinishing {
                    self.onFailure(error)
                }
            }
        }
    }

    /// Splits a result into words. A run of text carries one time range, which can cover
    /// several words, so those share it in proportion to length.
    static func words(from text: AttributedString, isMe: Bool, startedAt: Date) -> [SpokenWord] {
        var words: [SpokenWord] = []
        for run in text.runs {
            let content = String(text[run.range].characters)
            guard let range = run.audioTimeRange else { continue }
            let confidence = Float(run.transcriptionConfidence ?? 0)
            let parts = content.split(whereSeparator: \.isWhitespace).map(String.init)
            guard !parts.isEmpty else { continue }
            let total = max(parts.reduce(0) { $0 + $1.count }, 1)
            var offset = range.start.seconds
            for part in parts {
                let duration = range.duration.seconds * Double(part.count) / Double(total)
                words.append(SpokenWord(
                    text: part,
                    time: startedAt.addingTimeInterval(offset),
                    duration: duration,
                    confidence: confidence,
                    isMe: isMe
                ))
                offset += duration
            }
        }
        return words
    }

    private func convert(_ buffer: AVAudioPCMBuffer, to format: AVAudioFormat) -> AVAudioPCMBuffer? {
        if buffer.format == format { return buffer }
        if converter?.inputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: format)
        }
        guard let converter else { return nil }
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 64)
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
        nonisolated(unsafe) var supplied = false
        nonisolated(unsafe) let source = buffer
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, outcome in
            if supplied {
                outcome.pointee = .noDataNow
                return nil
            }
            supplied = true
            outcome.pointee = .haveData
            return source
        }
        return status == .error ? nil : output
    }
}
