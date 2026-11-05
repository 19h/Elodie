import AppKit
import SwiftUI

/// The rule for controls over recorded frames: glass is for controls, never for
/// reading surfaces. A frame can show anything, so the backdrop has to be made stable
/// before glass samples it.
public enum ChromeMetrics {
    /// The tallest the scrim reaches up from the bottom of the screen.
    public static let scrimHeight: CGFloat = 180
    /// How dark the scrim gets at the bottom of the screen.
    public static let scrimOpacity: Double = 0.6
    /// How dark it gets when the system's Reduce Transparency is on.
    public static let reducedTransparencyOpacity: Double = 0.85
    /// Panels that hold reading text stay nearly opaque.
    public static let readingSurfaceOpacity: Double = 0.92
}

/// Darkens the bottom of the screen, so controls have a stable backdrop on any frame.
public struct ChromeScrim: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    public init() {}

    public var body: some View {
        let peak = reduceTransparency ? ChromeMetrics.reducedTransparencyOpacity : ChromeMetrics.scrimOpacity
        LinearGradient(
            colors: [.black.opacity(0), .black.opacity(peak)],
            startPoint: .top,
            endPoint: .bottom
        )
        .frame(height: ChromeMetrics.scrimHeight)
        .allowsHitTesting(false)
    }
}

/// A control on recorded content: regular glass, always dark, with white text.
public struct ChromeControlStyle: ButtonStyle {
    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .glassEffect(.regular.interactive(), in: .capsule)
            .opacity(configuration.isPressed ? 0.8 : 1)
            .environment(\.colorScheme, .dark)
    }
}

/// A panel that holds text to read, solid enough that a frame behind it can't
/// interfere.
public struct ReadingSurface<Content: View>: View {
    private let cornerRadius: CGFloat
    private let content: Content

    public init(cornerRadius: CGFloat = 20, @ViewBuilder content: () -> Content) {
        self.cornerRadius = cornerRadius
        self.content = content()
    }

    public var body: some View {
        content
            .background(
                Color(white: 0.09).opacity(ChromeMetrics.readingSurfaceOpacity),
                in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(.white.opacity(0.08))
            )
            .environment(\.colorScheme, .dark)
    }
}
