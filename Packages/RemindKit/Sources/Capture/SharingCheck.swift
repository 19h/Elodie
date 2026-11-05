#if DEBUG
import CoreImage
import CoreMedia
import ScreenCaptureKit

/// What another app would get by capturing a whole display, as screen sharing does. This is how
/// to find out whether a window really stays out of it: only a capture from another process
/// can say, because a process always gets different answers about its own windows.
public enum SharingCheck {
    public struct Seen: Sendable {
        /// Marker-coloured pixels in the place asked about, sampled every 4 pixels.
        public var inScreenshot: Int
        public var inStream: Int
        /// Whether the system lists the window to other apps at all.
        public var isListed: Bool
        /// Marker-coloured pixels when another app asks for just this window, or `nil` if it
        /// couldn't get a picture at all.
        public var inWindowCapture: Int?
    }

    private final class Frames: NSObject, SCStreamOutput, @unchecked Sendable {
        private let lock = NSLock()
        private var latest: CVPixelBuffer?

        var frame: CVPixelBuffer? { lock.withLock { latest } }

        func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
            guard type == .screen, let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
            lock.withLock { latest = buffer }
        }
    }

    /// Counts pixels of the marker colour, magenta, in a rectangle given in points from the
    /// display's top left.
    public static func look(displayID: CGDirectDisplayID, rect: CGRect, windowID: CGWindowID) async throws -> Seen {
        let content = try await SCShareableContent.current
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw CocoaError(.featureUnsupported)
        }
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let configuration = SCStreamConfiguration()
        configuration.width = display.width * 2
        configuration.height = display.height * 2
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.colorSpaceName = CGColorSpace.sRGB
        configuration.showsCursor = false
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 10)

        let screenshot = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)

        let frames = Frames()
        let stream = SCStream(filter: filter, configuration: configuration, delegate: nil)
        try stream.addStreamOutput(frames, type: .screen, sampleHandlerQueue: DispatchQueue(label: "remind-sharing-check"))
        try await stream.startCapture()
        try await Task.sleep(for: .seconds(1))
        try await stream.stopCapture()

        var inStream = 0
        if let buffer = frames.frame {
            let image = CIImage(cvPixelBuffer: buffer)
            if let converted = CIContext().createCGImage(image, from: image.extent) {
                inStream = count(in: converted, rect: rect)
            }
        }
        var inWindowCapture: Int?
        if let window = content.windows.first(where: { $0.windowID == windowID }) {
            let only = SCContentFilter(desktopIndependentWindow: window)
            let settings = SCStreamConfiguration()
            settings.width = Int(window.frame.width) * 2
            settings.height = Int(window.frame.height) * 2
            settings.colorSpaceName = CGColorSpace.sRGB
            if let picture = try? await SCScreenshotManager.captureImage(contentFilter: only, configuration: settings) {
                inWindowCapture = count(in: picture, rect: CGRect(x: 0, y: 0, width: window.frame.width, height: window.frame.height))
            }
        }
        return Seen(
            inScreenshot: count(in: screenshot, rect: rect),
            inStream: inStream,
            isListed: content.windows.contains { $0.windowID == windowID },
            inWindowCapture: inWindowCapture
        )
    }

    private static func count(in image: CGImage, rect: CGRect) -> Int {
        let width = image.width
        let height = image.height
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ), let data = context.data else { return 0 }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let pixels = data.bindMemory(to: UInt8.self, capacity: width * height * 4)
        let scale = 2
        var found = 0
        // The context's memory starts at the top row.
        for y in stride(from: Int(rect.minY) * scale, to: min(Int(rect.maxY) * scale, height), by: 4) {
            for x in stride(from: Int(rect.minX) * scale, to: min(Int(rect.maxX) * scale, width), by: 4) {
                let at = (y * width + x) * 4
                if pixels[at] > 180, pixels[at + 1] < 90, pixels[at + 2] > 180 { found += 1 }
            }
        }
        return found
    }
}
#endif
