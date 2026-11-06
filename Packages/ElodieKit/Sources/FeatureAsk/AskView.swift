import AppKit
import CoreAPI
import DesignSystem
import Observation
import SwiftUI

/// One question and what came back.
@MainActor
@Observable
public final class AskExchange: Identifiable {
    public let id = UUID()
    public let question: String
    public var sources: [AskSource] = []
    public var answer = ""
    public var note: String?
    public var isFinished = false

    init(question: String) {
        self.question = question
    }
}

@MainActor
@Observable
public final class AskModel {
    public private(set) var exchanges: [AskExchange] = []
    public var draft = ""
    public private(set) var isAnswering = false

    private let engine: AskEngine
    private var task: Task<Void, Never>?

    public init(engine: AskEngine) {
        self.engine = engine
    }

    public func send() {
        let question = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !isAnswering else { return }
        draft = ""
        let exchange = AskExchange(question: question)
        exchanges.append(exchange)
        isAnswering = true
        let engine = self.engine
        task = Task { [weak self] in
            for await update in engine.ask(question) {
                switch update {
                case .sources(let sources): exchange.sources = sources
                case .answer(let text): exchange.answer = text
                case .noAnswer(let note): exchange.note = note
                }
            }
            exchange.isFinished = true
            self?.isAnswering = false
        }
    }

    public func stop() {
        task?.cancel()
        task = nil
        isAnswering = false
    }
}

/// The Ask window: a conversation over your recorded history.
public struct AskView: View {
    @Bindable private var model: AskModel
    private let onOpenMoment: (SearchHit) -> Void

    public init(model: AskModel, onOpenMoment: @escaping (SearchHit) -> Void) {
        self.model = model
        self.onOpenMoment = onOpenMoment
    }

    public var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        if model.exchanges.isEmpty {
                            welcome
                        }
                        ForEach(model.exchanges) { exchange in
                            ExchangeView(exchange: exchange, onOpenMoment: onOpenMoment)
                                .id(exchange.id)
                        }
                    }
                    .padding(20)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: model.exchanges.last?.answer) {
                    if let last = model.exchanges.last { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
            Divider()
            composer
        }
        .frame(minWidth: 480, minHeight: 500)
        .tint(Palette.verdigris)
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Ask about anything you've seen")
                .font(.system(size: 22, design: .serif))
            Text("Answers come from your recordings, and they're written on this Mac. Nothing is sent anywhere.")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 6) {
                suggestion("What was I working on yesterday?")
                suggestion("Where did I see the budget numbers?")
                suggestion("What did that error message say?")
            }
            .padding(.top, 8)
        }
    }

    private func suggestion(_ text: String) -> some View {
        Button {
            model.draft = text
            model.send()
        } label: {
            Text(text)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(.quaternary, in: Capsule())
        }
        .buttonStyle(.plain)
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 10) {
            TextField("Ask about anything you've seen", text: $model.draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 15))
                .lineLimit(1...5)
                .onSubmit { model.send() }
            if model.isAnswering {
                Button { model.stop() } label: {
                    Image(systemName: "stop.circle.fill").font(.system(size: 22))
                }
                .buttonStyle(.plain)
                .help("Stop")
            } else {
                Button { model.send() } label: {
                    Image(systemName: "arrow.up.circle.fill").font(.system(size: 22))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Palette.verdigris)
                .disabled(model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .help("Ask")
            }
        }
        .padding(14)
    }
}

private struct ExchangeView: View {
    let exchange: AskExchange
    let onOpenMoment: (SearchHit) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(exchange.question)
                .font(.system(size: 15, weight: .semibold))
                .frame(maxWidth: .infinity, alignment: .trailing)

            if !exchange.answer.isEmpty {
                answerText.textSelection(.enabled)
                    .environment(\.openURL, OpenURLAction { url in
                        guard url.scheme == "elodie-source", let number = url.host().flatMap(Int.init),
                              let source = exchange.sources.first(where: { $0.number == number })
                        else { return .discarded }
                        onOpenMoment(source.hit)
                        return .handled
                    })
            } else if exchange.note == nil, !exchange.isFinished {
                ProgressView().controlSize(.small)
            }

            if let note = exchange.note {
                Text(note).foregroundStyle(.secondary)
            }

            if !exchange.sources.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Sources")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                    ForEach(exchange.sources) { source in
                        Button { onOpenMoment(source.hit) } label: {
                            HStack(spacing: 8) {
                                Text("\(source.number)")
                                    .font(.system(size: 11, weight: .bold))
                                    .frame(width: 18, height: 18)
                                    .background(.quaternary, in: Circle())
                                Text(source.hit.window ?? "Unknown").lineLimit(1)
                                Spacer()
                                Text(TimeLabel.text(for: source.hit.capturedAt, now: Date()))
                                    .foregroundStyle(.secondary)
                            }
                            .font(.system(size: 13))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private var answerText: Text {
        let range = exchange.sources.isEmpty ? nil : 1...exchange.sources.count
        var attributed = AttributedString()
        for part in AnswerParser.parts(of: exchange.answer, validSources: range) {
            switch part {
            case .text(let text):
                attributed += AttributedString(text)
            case .citation(let number):
                var link = AttributedString("[\(number)]")
                link.link = URL(string: "elodie-source://\(number)")
                attributed += link
            }
        }
        return Text(attributed)
    }
}
