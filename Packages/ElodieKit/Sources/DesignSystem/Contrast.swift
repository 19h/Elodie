import Foundation

/// Checks that text stays readable, using the WCAG contrast formula.
public enum Contrast {
    /// Relative luminance of an sRGB colour with components from 0 to 1.
    public static func luminance(red: Double, green: Double, blue: Double) -> Double {
        func linear(_ value: Double) -> Double {
            value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }

    /// The contrast ratio between two luminances, from 1 to 21.
    public static func ratio(_ a: Double, _ b: Double) -> Double {
        (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    /// The luminance of a colour after a black layer of this opacity goes over it.
    public static func darkened(luminance: Double, by opacity: Double) -> Double {
        // Compositing happens in sRGB, so this converts there and back.
        func toGamma(_ value: Double) -> Double {
            value <= 0.0031308 ? value * 12.92 : 1.055 * pow(value, 1 / 2.4) - 0.055
        }
        func toLinear(_ value: Double) -> Double {
            value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return toLinear(toGamma(luminance) * (1 - opacity))
    }
}
