import DesignSystem
import SwiftUI
import UniformTypeIdentifiers

/// Shown when recordings exist but the key to them doesn't. It offers the only two ways
/// forward: bring the key back, or knowingly start again.
public struct RecoveryView: View {
    public enum Outcome: Sendable, Equatable {
        case restored
        /// The key was well formed, but it isn't the one for these recordings.
        case wrongKey
        case notAKey
        case failed(String)
    }

    private let onRestore: (String) async -> Outcome
    private let onStartOver: () -> Void
    private let onQuit: () -> Void

    @State private var text = ""
    @State private var message: LocalizedStringKey?
    @State private var isWorking = false
    @State private var confirmingStartOver = false

    public init(
        onRestore: @escaping (String) async -> Outcome,
        onStartOver: @escaping () -> Void,
        onQuit: @escaping () -> Void
    ) {
        self.onRestore = onRestore
        self.onStartOver = onStartOver
        self.onQuit = onQuit
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                Image(systemName: "key.slash")
                    .font(.system(size: 30))
                    .foregroundStyle(Palette.verdigris)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Remind can't unlock your recordings")
                        .font(.system(size: 17, weight: .semibold))
                    Text("The key that protects them isn't in your keychain.")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("If you saved a recovery key, enter it here, or choose the file you saved.")
                    .font(.system(size: 13))
                TextField("XXXXXXXX-XXXXXXXX-XXXXXXXX-XXXXXXXX-…", text: $text, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 13, design: .monospaced))
                    .lineLimit(2...3)
                    .onSubmit(unlock)
                    .disabled(isWorking)
                if let message {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            HStack {
                Button("Choose file…", action: chooseFile)
                    .disabled(isWorking)
                Spacer()
                if isWorking {
                    ProgressView().controlSize(.small)
                }
                Button("Unlock", action: unlock)
                    .buttonStyle(PrimaryActionStyle())
                    .keyboardShortcut(.defaultAction)
                    .disabled(isWorking || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            Divider()

            HStack {
                Text("No recovery key? Your recordings can't be read without one.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Quit", action: onQuit)
                Button("Start over…", role: .destructive) { confirmingStartOver = true }
            }
        }
        .padding(24)
        .frame(width: 520)
        .tint(Palette.verdigris)
        .alert("Delete your recordings and start over?", isPresented: $confirmingStartOver) {
            Button("Delete recordings", role: .destructive, action: onStartOver)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Without the key they can never be read, so they'd only take up space. This can't be undone.")
        }
    }

    private func unlock() {
        guard !isWorking else { return }
        isWorking = true
        message = nil
        Task {
            let outcome = await onRestore(text)
            isWorking = false
            switch outcome {
            case .restored: break
            case .wrongKey: message = "That's a valid key, but it isn't the one for these recordings."
            case .notAKey: message = "That doesn't look like a recovery key. It should have 64 letters and numbers."
            case .failed(let reason): message = "Remind couldn't use that key. \(reason)"
            }
        }
    }

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.plainText, .text]
        panel.message = String(localized: "Choose the recovery key file you saved.")
        guard panel.runModal() == .OK, let url = panel.url,
              let contents = try? String(contentsOf: url, encoding: .utf8)
        else { return }
        text = contents
        unlock()
    }
}
