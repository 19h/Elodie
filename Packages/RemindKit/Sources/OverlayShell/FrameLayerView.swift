import AppKit
import CoreVideo
import IOSurface
import QuartzCore

/// Shows a recorded frame without copying it. The compositor reads the decoded surface
/// directly, so a frame change costs only a property update.
public final class FrameLayerView: NSView {
    private let frameLayer = CALayer()
    private let selectionLayer = CAShapeLayer()

    public override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer = CALayer()
        layer?.backgroundColor = NSColor.black.cgColor
        frameLayer.contentsGravity = .resizeAspect
        frameLayer.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull()]
        frameLayer.frame = bounds
        layer?.addSublayer(frameLayer)
        selectionLayer.fillColor = NSColor.controlAccentColor.withAlphaComponent(0.35).cgColor
        selectionLayer.actions = ["path": NSNull(), "bounds": NSNull(), "position": NSNull()]
        selectionLayer.frame = bounds
        layer?.addSublayer(selectionLayer)
    }

    /// Draws selected text. Rects are fractions of the frame, with the origin at the top left.
    public func showSelection(_ rects: [CGRect]) {
        let path = CGMutablePath()
        for rect in rects {
            path.addRoundedRect(
                in: CGRect(
                    x: rect.minX * bounds.width - 1,
                    y: (1 - rect.maxY) * bounds.height - 1,
                    width: rect.width * bounds.width + 2,
                    height: rect.height * bounds.height + 2
                ),
                cornerWidth: 2,
                cornerHeight: 2
            )
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        selectionLayer.frame = bounds
        selectionLayer.path = path
        CATransaction.commit()
    }

    /// Stops showing a frame, so an old moment can't flash up the next time this opens.
    public func clear() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        frameLayer.contents = nil
        selectionLayer.path = nil
        CATransaction.commit()
    }

    /// Grows the picture out of a rectangle to fill the screen, over what was showing.
    public func flyIn(from rect: NSRect, duration: CFTimeInterval = 0.24) {
        guard bounds.width > 0, bounds.height > 0, let previous = frameLayer.contents else { return }
        let backdrop = CALayer()
        backdrop.frame = bounds
        backdrop.contents = previous
        backdrop.contentsGravity = .resizeAspect
        backdrop.contentsScale = frameLayer.contentsScale
        layer?.insertSublayer(backdrop, below: frameLayer)

        let scale = CATransform3DMakeScale(rect.width / bounds.width, rect.height / bounds.height, 1)
        let start = CATransform3DTranslate(
            CATransform3DIdentity,
            rect.midX - bounds.midX,
            rect.midY - bounds.midY,
            0
        )
        let animation = CABasicAnimation(keyPath: "transform")
        animation.fromValue = CATransform3DConcat(scale, start)
        animation.toValue = CATransform3DIdentity
        animation.duration = duration
        animation.timingFunction = CAMediaTimingFunction(name: .easeOut)

        CATransaction.begin()
        CATransaction.setCompletionBlock { backdrop.removeFromSuperlayer() }
        frameLayer.add(animation, forKey: "flyIn")
        CATransaction.commit()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Not used") }

    public override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        frameLayer.frame = bounds
        selectionLayer.frame = bounds
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
