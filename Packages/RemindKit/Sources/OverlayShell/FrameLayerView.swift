import AppKit
import CoreVideo
import IOSurface
import QuartzCore

/// Shows a recorded frame without copying it. The compositor reads the decoded surface
/// directly, so a frame change costs only a property update.
public final class FrameLayerView: NSView {
    private let frameLayer = CALayer()

    public override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer = CALayer()
        layer?.backgroundColor = NSColor.black.cgColor
        frameLayer.contentsGravity = .resizeAspect
        frameLayer.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull()]
        frameLayer.frame = bounds
        layer?.addSublayer(frameLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Not used") }

    public override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        frameLayer.frame = bounds
        CATransaction.commit()
    }

    /// Shows a decoded frame. Call on the main thread.
    public func show(_ buffer: CVPixelBuffer) {
        guard let surface = CVPixelBufferGetIOSurface(buffer)?.takeUnretainedValue() else { return }
        // Frames are captured in display P3, and this tells the compositor so.
        IOSurfaceSetValue(surface, "IOSurfaceColorSpace" as CFString, CGColorSpace.displayP3 as CFString)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        frameLayer.contents = surface
        frameLayer.contentsScale = window?.backingScaleFactor ?? 2
        CATransaction.commit()
    }

    /// The surface being shown, which tests can read back to prove what's on screen.
    public var shownSurface: IOSurfaceRef? {
        guard let contents = frameLayer.contents else { return nil }
        guard CFGetTypeID(contents as CFTypeRef) == IOSurfaceGetTypeID() else { return nil }
        return (contents as! IOSurfaceRef)
    }
}
