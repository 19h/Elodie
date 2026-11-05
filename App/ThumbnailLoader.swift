import CoreAPI
import CoreGraphics
import CoreImage
import CoreText
import CoreVideo
import FrameEngine
import Foundation

/// Decodes a search result's frame and crops around its match.
enum ThumbnailLoader {
    private static let context = CIContext()
    /// The crop's width as a fraction of the frame, so the match has some context.
    private static let cropWidth: CGFloat = 0.30

    static func crop(core: any RemindCore, hit: SearchHit) async -> CGImage? {
        await Task.detached(priority: .utility) { () -> CGImage? in
            guard let group = try? core.readGroup(containing: hit.frameID),
                  let decoder = try? HEVCDecoder(parameterSets: group.parameterSets, width: group.width, height: group.height)
            else { return nil }
            var buffer: CVPixelBuffer?
            for sample in group.samples[...group.target] {
                buffer = try? decoder.decode(sample.data)
            }
            guard let buffer else { return nil }
            let image = CIImage(cvPixelBuffer: buffer)
            let size = image.extent.size
            let focus = hit.rects.first ?? CGRect(x: 0.35, y: 0.35, width: 0.3, height: 0.3)

            let width = size.width * cropWidth
            let height = width * 0.68
            // Core Image's origin is at the bottom left, and match rects use the top left.
            let centerX = focus.midX * size.width
            let centerY = (1 - focus.midY) * size.height
            let crop = CGRect(
                x: min(max(centerX - width / 2, 0), size.width - width),
                y: min(max(centerY - height / 2, 0), size.height - height),
                width: width,
                height: height
            )
            guard let cropped = context.createCGImage(image, from: crop) else { return nil }
            return marked(cropped, crop: crop, frameSize: size, rects: hit.rects) ?? cropped
        }.value
    }

    /// Draws the marker around each match, numbered when there's more than one.
    private static func marked(_ image: CGImage, crop: CGRect, frameSize: CGSize, rects: [CGRect]) -> CGImage? {
        guard !rects.isEmpty,
              let drawing = CGContext(
                  data: nil,
                  width: image.width,
                  height: image.height,
                  bitsPerComponent: 8,
                  bytesPerRow: 0,
                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
              )
        else { return nil }
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        drawing.draw(image, in: bounds)
        // Cards are about 300 points wide, so this keeps the marker the same weight.
        let unit = CGFloat(image.width) / 300
        let marker = CGColor(srgbRed: 1, green: 0.784, blue: 0.239, alpha: 1)
        for (index, rect) in rects.enumerated() {
            // Match rects use a top-left origin, and this context uses the bottom left.
            let box = CGRect(
                x: rect.minX * frameSize.width - crop.minX,
                y: (1 - rect.maxY) * frameSize.height - crop.minY,
                width: rect.width * frameSize.width,
                height: rect.height * frameSize.height
            ).insetBy(dx: -2.5 * unit, dy: -1.5 * unit)
            guard box.intersects(bounds) else { continue }
            let path = CGPath(roundedRect: box, cornerWidth: 3 * unit, cornerHeight: 3 * unit, transform: nil)
            drawing.addPath(path)
            drawing.setFillColor(marker.copy(alpha: 0.16)!)
            drawing.fillPath()
            drawing.addPath(path)
            drawing.setStrokeColor(marker)
            drawing.setLineWidth(1.5 * unit)
            drawing.strokePath()
            if rects.count > 1 {
                badge(index + 1, at: CGPoint(x: box.minX, y: box.maxY), unit: unit, marker: marker, in: drawing)
            }
        }
        return drawing.makeImage()
    }

    private static func badge(_ number: Int, at center: CGPoint, unit: CGFloat, marker: CGColor, in drawing: CGContext) {
        let radius = 8 * unit
        drawing.setFillColor(marker)
        drawing.fillEllipse(in: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
        let font = CTFontCreateUIFontForLanguage(.emphasizedSystem, 11 * unit, nil)
        let text = NSAttributedString(string: "\(number)", attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font as Any,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1),
        ])
        let line = CTLineCreateWithAttributedString(text)
        let width = CTLineGetTypographicBounds(line, nil, nil, nil)
        drawing.textPosition = CGPoint(x: center.x - width / 2, y: center.y - 4 * unit)
        CTLineDraw(line, drawing)
    }
}
