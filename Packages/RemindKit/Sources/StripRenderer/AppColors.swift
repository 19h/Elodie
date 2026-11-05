import AppKit
import simd

/// Picks a timeline colour for an app from its icon.
public enum AppColors {
    /// The colour to use for an icon's pixels, given their average.
    ///
    /// Many icons are nearly black or white, and those would disappear against the
    /// dark strip or glare. Colours are kept to a range that reads as a colour on the
    /// strip, with a neutral grey for icons that have no colour of their own.
    public static func stripColor(averageRed: Double, green: Double, blue: Double) -> SIMD4<Float> {
        let high = max(averageRed, green, blue)
        let low = min(averageRed, green, blue)
        let saturation = high > 0 ? (high - low) / high : 0

        // Almost no colour, so use a mid grey that's visible on the dark strip.
        if saturation < 0.15 {
            return SIMD4(0.62, 0.64, 0.68, 1)
        }

        // Bring the brightest channel to a fixed level, so every app reads with the
        // same strength, then lift the floor so the colour isn't harsh.
        let scale = 0.86 / max(high, 0.001)
        let floor = 0.22
        func adjust(_ channel: Double) -> Float {
            Float(min(max(channel * scale, floor), 0.92))
        }
        return SIMD4(adjust(averageRed), adjust(green), adjust(blue), 1)
    }

    /// The strip colour for an app's icon. Reads the icon once, and callers should keep
    /// the answer.
    @MainActor
    public static func stripColor(forBundleID bundleID: String?) -> SIMD4<Float> {
        guard let bundleID,
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        else {
            return stripColor(averageRed: 0.5, green: 0.5, blue: 0.5)
        }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        return stripColor(icon: icon)
    }

    @MainActor
    static func stripColor(icon: NSImage) -> SIMD4<Float> {
        let size = 16
        guard let context = CGContext(
            data: nil,
            width: size,
            height: size,
            bitsPerComponent: 8,
            bytesPerRow: size * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ),
            let cgImage = icon.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else {
            return stripColor(averageRed: 0.5, green: 0.5, blue: 0.5)
        }
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: size, height: size))
        guard let data = context.data else {
            return stripColor(averageRed: 0.5, green: 0.5, blue: 0.5)
        }
        let pixels = data.assumingMemoryBound(to: UInt8.self)
        var red = 0.0, green = 0.0, blue = 0.0, weight = 0.0
        for index in 0..<(size * size) {
            let alpha = Double(pixels[index * 4 + 3]) / 255
            guard alpha > 0.5 else { continue }
            let r = Double(pixels[index * 4]) / 255
            let g = Double(pixels[index * 4 + 1]) / 255
            let b = Double(pixels[index * 4 + 2]) / 255
            // Vivid pixels say more about an icon's colour than greys do.
            let vividness = max(r, g, b) - min(r, g, b)
            let share = alpha * (0.15 + vividness)
            red += r * share
            green += g * share
            blue += b * share
            weight += share
        }
        guard weight > 0 else {
            return stripColor(averageRed: 0.5, green: 0.5, blue: 0.5)
        }
        return stripColor(averageRed: red / weight, green: green / weight, blue: blue / weight)
    }
}
