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
    /// How dark the fill behind control text is. Glass over a white page reads as pale grey,
    /// and it adapts any tint to what's behind it, so white text needs a fill of its own.
    /// This does the job without darkening more of the frame, so it still looks like your
    /// screen. The contrast scenarios measure this against the 4.5:1 gate.
    public static let controlFillOpacity: Double = 0.6
    /// Panels that hold reading text stay nearly opaque.
    public static let readingSurfaceOpacity: Double = 0.94
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
            .background(.black.opacity(ChromeMetrics.controlFillOpacity), in: .capsule)
            .glassEffect(.regular.interactive(), in: .capsule)
            .opacity(configuration.isPressed ? 0.8 : 1)
            .environment(\.colorScheme, .dark)
    }
}

/// The one thing to do next. It's drawn here rather than by the system, because a
/// window can be inactive at exactly the moment this matters: while someone's away in
/// System Settings granting a permission, a system button would turn grey.
public struct PrimaryActionStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    private let font: Font
    private let horizontalPadding: CGFloat
    private let verticalPadding: CGFloat

    public init(font: Font = .system(size: 14, weight: .semibold), horizontalPadding: CGFloat = 14, verticalPadding: CGFloat = 7) {
        self.font = font
        self.horizontalPadding = horizontalPadding
        self.verticalPadding = verticalPadding
    }

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(font)
            .foregroundStyle(Palette.onVerdigris)
            .padding(.horizontal, horizontalPadding)
            .padding(.vertical, verticalPadding)
            .background(configuration.isPressed ? Palette.verdigrisDeep : Palette.verdigris, in: Capsule())
            .contentShape(Capsule())
            .opacity(isEnabled ? 1 : 0.35)
    }
}

/// A round control on recorded content, for a single symbol.
public struct ChromeIconStyle: ButtonStyle {
    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 36, height: 36)
            .contentShape(Circle())
            .background(.black.opacity(ChromeMetrics.controlFillOpacity), in: .circle)
            .glassEffect(.regular.interactive(), in: .circle)
            .opacity(configuration.isPressed ? 0.8 : 1)
            .environment(\.colorScheme, .dark)
    }
}

/// A panel that holds text to read, solid enough that a frame behind it can't
/// interfere. The little that does come through is blurred, so it can't be read.
public struct ReadingSurface<Content: View>: View {
    private let cornerRadius: CGFloat
    private let content: Content

    public init(cornerRadius: CGFloat = 20, @ViewBuilder content: () -> Content) {
        self.cornerRadius = cornerRadius
        self.content = content()
    }

    public var body: some View {
        content
            .background {
                let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                ZStack {
                    shape.fill(.ultraThinMaterial)
                    shape.fill(Color(white: 0.12).opacity(ChromeMetrics.readingSurfaceOpacity))
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(.white.opacity(0.08))
            )
            .environment(\.colorScheme, .dark)
    }
}
