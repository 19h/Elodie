import Foundation
import FoundationModels

/// Why the on-device model can't answer right now, in terms someone can act on.
public enum ModelUnavailable: Equatable, Sendable {
    case deviceNotSupported
    case appleIntelligenceOff
    case stillDownloading
    case other

    public var message: String {
        switch self {
        case .deviceNotSupported:
            String(localized: "This Mac doesn't support Apple's on-device model, so Ask can only show matching moments.")
        case .appleIntelligenceOff:
            String(localized: "Turn on Apple Intelligence in System Settings to get written answers. Until then, Ask shows matching moments.")
        case .stillDownloading:
            String(localized: "Apple's on-device model is still downloading. Until it's ready, Ask shows matching moments.")
        case .other:
            String(localized: "Apple's on-device model isn't available right now, so Ask shows matching moments.")
        }
    }
}

/// Writes answers. This is a protocol so tests don't depend on a model.
public protocol AnswerGenerator: Sendable {
    /// Why it can't answer, or `nil` if it can.
    var unavailableReason: ModelUnavailable? { get }
    /// How many tokens fit in one request.
    var contextSize: Int { get }
    func tokenCount(_ text: String) async -> Int
    /// Streams the answer as it's written, each element being everything so far.
    func answer(instructions: String, prompt: String) -> AsyncThrowingStream<String, any Error>
}

/// Apple's on-device model. Nothing leaves this Mac: `SystemLanguageModel` runs
/// locally, and it's deliberately used by name rather than through anything that
/// could choose a cloud model. It has no tools, so text from the screen can't make it
/// do anything. The worst a hostile page could do is mislead an answer.
public struct OnDeviceAnswerGenerator: AnswerGenerator {
    private let model = SystemLanguageModel.default

    public init() {}

    public var unavailableReason: ModelUnavailable? {
        switch model.availability {
        case .available:
            return nil
        case .unavailable(.deviceNotEligible):
            return .deviceNotSupported
        case .unavailable(.appleIntelligenceNotEnabled):
            return .appleIntelligenceOff
        case .unavailable(.modelNotReady):
            return .stillDownloading
        case .unavailable:
            return .other
        @unknown default:
            return .other
        }
    }

    public var contextSize: Int {
        if #available(macOS 26.4, *) {
            return model.contextSize
        }
        // What the model allowed before it could report its size.
        return 4096
    }

    public func tokenCount(_ text: String) async -> Int {
        // A rough estimate of 3 characters per token errs high, so if exact counting
        // isn't possible, this still stays within the limit.
        if #available(macOS 26.4, *), let exact = try? await model.tokenCount(for: Prompt(text)) {
            return exact
        }
        return text.count / 3
    }

    public func answer(instructions: String, prompt: String) -> AsyncThrowingStream<String, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let session = LanguageModelSession(model: model, tools: [], instructions: instructions)
                    for try await snapshot in session.streamResponse(to: prompt) {
                        continuation.yield(snapshot.content)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
