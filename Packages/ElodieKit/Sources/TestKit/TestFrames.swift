import CoreGraphics
import CoreText
import CoreVideo
import Foundation
import VideoToolbox

/// Simple frames with exactly known pixels.
public enum TestFrames {
    /// A flat bi-planar frame, optionally with a rectangle of a different luma.
    public static func flat(
        width: Int = 640,
        height: Int = 400,
        luma: UInt8,
        rect: (x: Int, y: Int, width: Int, height: Int)? = nil,
        rectLuma: UInt8 = 255
    ) -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let attributes: [CFString: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey: [String: Any](),
            kCVPixelBufferMetalCompatibilityKey: true,
        ]
        CVPixelBufferCreate(
            kCFAllocatorDefault, width, height, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
            attributes as CFDictionary, &buffer
        )
        let frame = buffer!
        CVPixelBufferLockBaseAddress(frame, [])
        let y = CVPixelBufferGetBaseAddressOfPlane(frame, 0)!.assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRowOfPlane(frame, 0)
        memset(y, Int32(luma), stride * height)
        let chroma = CVPixelBufferGetBaseAddressOfPlane(frame, 1)!
        memset(chroma, 128, CVPixelBufferGetBytesPerRowOfPlane(frame, 1) * height / 2)
        if let rect {
            for row in rect.y..<(rect.y + rect.height) {
                memset(y + row * stride + rect.x, Int32(rectLuma), rect.width)
            }
        }
        CVPixelBufferUnlockBaseAddress(frame, [])
        return frame
    }

    /// A white frame with black text whose baseline starts at `point`, measured from
    /// the top left in pixels.
    public static func withText(_ text: String, width: Int, height: Int, at point: CGPoint) -> CVPixelBuffer {
        var bgra: CVPixelBuffer?
        let attributes: [CFString: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey: [String: Any](),
            kCVPixelBufferMetalCompatibilityKey: true,
        ]
        CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, attributes as CFDictionary, &bgra)
        let source = bgra!
        CVPixelBufferLockBaseAddress(source, [])
        let context = CGContext(
            data: CVPixelBufferGetBaseAddress(source),
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(source),
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        )!
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let font = CTFontCreateWithName("Helvetica" as CFString, 32, nil)
        let string = CFAttributedStringCreate(nil, text as CFString, [
            kCTFontAttributeName: font,
            kCTForegroundColorAttributeName: CGColor(gray: 0, alpha: 1),
        ] as CFDictionary)!
        context.textPosition = CGPoint(x: point.x, y: CGFloat(height) - point.y)
        CTLineDraw(CTLineCreateWithAttributedString(string), context)
        CVPixelBufferUnlockBaseAddress(source, [])

        var output: CVPixelBuffer?
        CVPixelBufferCreate(
            kCFAllocatorDefault, width, height, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
            attributes as CFDictionary, &output
        )
        var session: VTPixelTransferSession?
        VTPixelTransferSessionCreate(allocator: nil, pixelTransferSessionOut: &session)
        VTPixelTransferSessionTransferImage(session!, from: source, to: output!)
        return output!
    }
}
