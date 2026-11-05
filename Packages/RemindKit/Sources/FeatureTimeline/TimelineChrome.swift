import AppKit
import CoreAPI
import DesignSystem
import SwiftUI

/// The controls over a frame: the time pill and playhead, plus Open and overflow.
/// The strip itself is drawn underneath in Metal.
public struct TimelineChrome: View {
    @Bindable private var model: TimelineModel
    private let onOpen: () -> Void
    private let onJumpToNow: () -> Void
    private let overflow: AnyView

    public init(
        model: TimelineModel,
        onOpen: @escaping () -> Void,
        onJumpToNow: @escaping () -> Void,
        @ViewBuilder overflow: () -> some View
    ) {
        self.model = model
        self.onOpen = onOpen
        self.onJumpToNow = onJumpToNow
        self.overflow = AnyView(overflow())
    }

    public var body: some View {
        ZStack(alignment: .bottom) {
            ChromeScrim()

            GlassEffectContainer {
                HStack(alignment: .bottom) {
                    Spacer()
                    VStack(spacing: 0) {
                        timePill
                        playhead
                    }
                    Spacer()
                }
            }

            HStack(spacing: 8) {
                Spacer()
                if let context = model.currentContext, context.bundleID != nil || context.url != nil {
                    openButton(for: context)
                }
                overflow
                if !model.isAtNow {
                    Button(action: onJumpToNow) {
                        Image(systemName: "arrow.right")
                    }
                    .buttonStyle(ChromeControlStyle())
                    .help("Back to now")
                    .keyboardShortcut(.end, modifiers: [])
                }
            }
            .padding(.trailing, 24)
            .padding(.bottom, 78)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
    }

    private var timePill: some View {
        Button {
            model.isJumpToDateOpen.toggle()
        } label: {
            HStack(spacing: 6) {
                Text(model.timeLabel)
                    .monospacedDigit()
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white.opacity(0.7))
            }
        }
        .buttonStyle(ChromeControlStyle())
        .accessibilityLabel("Jump to a date and time. Showing \(model.timeLabel).")
        .padding(.bottom, 6)
    }

    /// White with a dark outline, so it reads on any frame.
    private var playhead: some View {
        RoundedRectangle(cornerRadius: 1.5)
            .fill(.white)
            .frame(width: 3, height: 66)
            .overlay(RoundedRectangle(cornerRadius: 1.5).strokeBorder(.black.opacity(0.45), lineWidth: 1).padding(-1))
            .allowsHitTesting(false)
    }

    private func openButton(for context: FrameContext) -> some View {
        Button(action: onOpen) {
            HStack(spacing: 6) {
                if let icon = Self.appIcon(for: context.bundleID) {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: 18, height: 18)
                }
                Text("Open")
            }
        }
        .buttonStyle(ChromeControlStyle())
        .help(context.url ?? "Open the app")
    }

    private static func appIcon(for bundleID: String?) -> NSImage? {
        guard let bundleID,
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        else { return nil }
        return NSWorkspace.shared.icon(forFile: url.path)
    }
}
