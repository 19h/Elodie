import CoreAPI
import CoreGraphics
import CoreImage
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
            return context.createCGImage(image, from: crop)
        }.value
    }
}
