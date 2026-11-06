// Test support, which has no place in a release build.
#if DEBUG
import CoreGraphics
import CoreVideo

/// A frame number drawn into the picture as black and white blocks, large enough
/// to survive compression. Tests read it back to prove which frame is showing.
public enum FrameBarcode {
    static let bits = 24
    static let cell = 24

    public static var size: CGSize {
        CGSize(width: bits * cell, height: cell)
    }

    /// Draws at the top left of a context with a top-left origin.
    static func draw(_ value: Int, in context: CGContext, originY: Int) {
        for bit in 0..<bits {
            let on = (value >> bit) & 1 == 1
            context.setFillColor(gray: on ? 1 : 0, alpha: 1)
            context.fill(CGRect(x: bit * cell, y: originY, width: cell, height: cell))
        }
    }

    /// Reads the value from the luma plane of a 4:2:0 buffer, or `nil` if the
    /// blocks are too ambiguous to trust.
    public static func read(from buffer: CVPixelBuffer, originY: Int) -> Int? {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddressOfPlane(buffer, 0) else {
            return nil
        }
        let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        let luma = base.assumingMemoryBound(to: UInt8.self)

        var value = 0
        for bit in 0..<bits {
            let x = bit * cell + cell / 2
            let y = originY + cell / 2
            let sample = Int(luma[y * stride + x])
            if sample > 170 {
                value |= 1 << bit
            } else if sample > 85 {
                return nil
            }
        }
        return value
    }
}
#endif
