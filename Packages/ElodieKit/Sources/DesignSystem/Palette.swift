import AppKit
import SwiftUI

/// Elodie's colours.
///
/// The accent is verdigris, the patina time leaves on copper. It's distinct from
/// system blue and from the red and orange macOS uses for its recording and
/// microphone indicators.
public enum Palette {
    public static let verdigris = dynamic(dark: 0x45C9B1, light: 0x0B7F70)
    public static let verdigrisDeep = dynamic(dark: 0x7FE3D0, light: 0x086B5D)
    /// Text and icons on a verdigris fill.
    public static let onVerdigris = dynamic(dark: 0x04211C, light: 0xFFFFFF)
    /// Search match highlights.
    public static let marker = Color(hex: 0xFFC83D)

    private static func dynamic(dark: UInt32, light: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return NSColor(hex: isDark ? dark : light)
        })
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(nsColor: NSColor(hex: hex))
    }
}

extension NSColor {
    convenience init(hex: UInt32) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}
