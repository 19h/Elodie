import AppKit
import CoreAPI
import DesignSystem
import SwiftUI

/// Where things sit at the bottom of the timeline, in points from the bottom edge.
enum TimelineMetrics {
    /// The strip is drawn in Metal, so it's laid out by the controller.
    static let stripBottom: CGFloat = 26
    static let stripHeight: CGFloat = 40
    static let stripCenter: CGFloat = stripBottom + stripHeight / 2
    static let playheadHeight: CGFloat = 74
    static let controlsBottom: CGFloat = playheadHeight + 6
}

/// The controls over a frame: the time pill, Open, and overflow. The strip and playhead
/// are drawn above these, outside SwiftUI, since they move on every scroll event.
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
                timePill
            }
            .padding(.bottom, TimelineMetrics.controlsBottom)

            HStack(spacing: 8) {
                Spacer()
                if let context = model.currentContext, context.bundleID != nil || context.url != nil {
                    openButton(for: context)
                }
                overflow
            }
            .padding(.trailing, 24)
            .padding(.bottom, TimelineMetrics.controlsBottom)

            // Sits at the end of the strip, which is where "now" is.
            if !model.isAtNow {
                HStack {
                    Spacer()
                    Button(action: onJumpToNow) {
                        Image(systemName: "arrow.right")
                    }
                    .buttonStyle(ChromeIconStyle())
                    .help("Back to now")
                    .keyboardShortcut(.end, modifiers: [])
                }
                .padding(.trailing, 24)
                .padding(.bottom, TimelineMetrics.stripCenter - 18)
            }
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
