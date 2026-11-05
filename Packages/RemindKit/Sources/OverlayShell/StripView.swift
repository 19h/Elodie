import AppKit
import Metal
import QuartzCore
import StripRenderer

/// A stretch with nothing recorded, squeezed down and labelled with how long it was.
public struct StripBreak: Equatable {
    public var start: Float
    public var end: Float
    public var label: String

    public init(start: Float, end: Float, label: String) {
        self.start = start
        self.end = end
        self.label = label
    }
}

/// What's drawn over the runs. Times are seconds from the same origin as the runs.
public struct StripOverlays: Equatable {
    /// The run under the pointer.
    public var hovered: ClosedRange<Float>?
    /// The stretch someone has picked out.
    public var selection: ClosedRange<Float>?
    /// Starred moments.
    public var stars: [Float]
    /// When something was being transcribed.
    public var speech: [ClosedRange<Float>]
    /// Where nothing was recorded.
    public var breaks: [StripBreak]

    public init(
        hovered: ClosedRange<Float>? = nil,
        selection: ClosedRange<Float>? = nil,
        stars: [Float] = [],
        speech: [ClosedRange<Float>] = [],
        breaks: [StripBreak] = []
    ) {
        self.hovered = hovered
        self.selection = selection
        self.stars = stars
        self.speech = speech
        self.breaks = breaks
    }
}

/// Takes the mouse over the strip, and leaves the rest alone.
public final class StripInteractionView: NSView {
    public enum Event {
        case moved(Double)
        case exited
        case down(Double, clicks: Int)
        case dragged(Double)
        case up(Double)
    }

    public var onEvent: ((Event) -> Void)?
    /// Scrolling over the strip moves through time, the same as anywhere else.
    public var onScroll: ((NSEvent) -> Void)?
    public var onMagnify: ((NSEvent) -> Void)?
    /// How much of the right end stays free, for the button that sits there.
    public var freeRight: CGFloat = 76
    private var tracking: NSTrackingArea?

    public override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        guard bounds.contains(local), local.x < bounds.maxX - freeRight else { return nil }
        return self
    }

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        tracking = area
    }

    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private func x(_ event: NSEvent) -> Double {
        Double(convert(event.locationInWindow, from: nil).x)
    }

    public override func mouseMoved(with event: NSEvent) { onEvent?(.moved(x(event))) }
    public override func mouseEntered(with event: NSEvent) { onEvent?(.moved(x(event))) }
    public override func mouseExited(with event: NSEvent) { onEvent?(.exited) }
    public override func mouseDown(with event: NSEvent) { onEvent?(.down(x(event), clicks: event.clickCount)) }
    public override func mouseDragged(with event: NSEvent) { onEvent?(.dragged(x(event))) }
    public override func mouseUp(with event: NSEvent) { onEvent?(.up(x(event))) }
    public override func scrollWheel(with event: NSEvent) { onScroll?(event) }
    public override func magnify(with event: NSEvent) { onMagnify?(event) }
}

/// An app icon to show on a run of the strip.
public struct StripIcon {
    public var start: Float
    public var end: Float
    public var image: CGImage

    public init(start: Float, end: Float, image: CGImage) {
        self.start = start
        self.end = end
        self.image = image
    }
}

/// Hosts the strip renderer on a Metal layer, with app icons on top.
public final class StripView: NSView, CALayerDelegate {
    private let device: any MTLDevice
    private let queue: any MTLCommandQueue
    private let metalLayer = CAMetalLayer()
    private let renderer: StripRenderer
    private var icons: [StripIcon] = []
    private var iconLayers: [CALayer] = []
    private var breakLayers: [CATextLayer] = []
    private let speechLayer = CAShapeLayer()
    private let starLayer = CAShapeLayer()
    private let hoverLayer = CAShapeLayer()
    private let selectionLayer = CAShapeLayer()
    private let handleLayer = CAShapeLayer()
    private var overlays = StripOverlays()
    private var capsuleHeight: CGFloat = 9
    /// Called the next time the strip reaches the screen, for measuring how fast opening is.
    public var onNextPresent: (@Sendable (CFTimeInterval) -> Void)?

    private static let iconSize: CGFloat = 24

    public init?(stripFrame frame: NSRect) {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue(),
              let renderer = try? StripRenderer(device: device, pixelFormat: .bgra8Unorm)
        else { return nil }
        self.device = device
        self.queue = queue
        self.renderer = renderer
        super.init(frame: frame)
        wantsLayer = true
        metalLayer.device = device
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.isOpaque = false
        metalLayer.framebufferOnly = true
        metalLayer.presentsWithTransaction = false
        layer = metalLayer
        speechLayer.fillColor = NSColor(srgbRed: 0.27, green: 0.79, blue: 0.69, alpha: 1).cgColor
        starLayer.fillColor = NSColor(srgbRed: 1, green: 0.784, blue: 0.239, alpha: 1).cgColor
        starLayer.shadowOpacity = 0.5
        starLayer.shadowRadius = 1.5
        starLayer.shadowOffset = .zero
        hoverLayer.fillColor = nil
        hoverLayer.strokeColor = NSColor.white.cgColor
        hoverLayer.lineWidth = 1.5
        selectionLayer.fillColor = NSColor.white.withAlphaComponent(0.14).cgColor
        selectionLayer.strokeColor = NSColor.white.cgColor
        selectionLayer.lineWidth = 2
        handleLayer.fillColor = NSColor.white.cgColor
        handleLayer.shadowOpacity = 0.5
        handleLayer.shadowRadius = 2
        handleLayer.shadowOffset = .zero
        for shape in [speechLayer, selectionLayer, hoverLayer, handleLayer, starLayer] {
            shape.actions = ["path": NSNull(), "bounds": NSNull(), "position": NSNull()]
            metalLayer.addSublayer(shape)
        }
    }

    /// Sets what's drawn over the runs, which appears at the next draw.
    public func setOverlays(_ overlays: StripOverlays) {
        self.overlays = overlays
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Not used") }

    public func setRuns(_ runs: [StripRun], icons: [StripIcon] = []) {
        renderer.setRuns(runs)
        self.icons = icons
    }

    /// Scrolling and clicks belong to whatever's underneath.
    public override func hitTest(_ point: NSPoint) -> NSView? { nil }

    public func draw(viewport: StripViewport) {
        let scale = window?.backingScaleFactor ?? 2
        let size = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        guard size.width > 0, size.height > 0 else { return }
        if metalLayer.drawableSize != size {
            metalLayer.drawableSize = size
            metalLayer.contentsScale = scale
        }
        guard let drawable = metalLayer.nextDrawable(),
              let commands = queue.makeCommandBuffer()
        else { return }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = commands.makeRenderCommandEncoder(descriptor: pass) else { return }
        var adjusted = viewport
        adjusted.scale = Double(scale)
        renderer.draw(in: encoder, viewport: adjusted)
        encoder.endEncoding()
        if let onNextPresent {
            drawable.addPresentedHandler { onNextPresent($0.presentedTime) }
            self.onNextPresent = nil
        }
        commands.present(drawable)
        commands.commit()
        layoutIcons(viewport: viewport)
        capsuleHeight = CGFloat(viewport.capsuleHeightPoints)
        layoutOverlays(viewport: viewport)
        layoutBreaks(viewport: viewport)
    }

    /// How long each break was, in the middle of it. These are plain layers like the icons,
    /// and there are only ever a few on screen.
    private func layoutBreaks(viewport: StripViewport) {
        let width = CGFloat(viewport.widthPoints)
        let height: CGFloat = 13
        let labelWidth: CGFloat = 60
        var used = 0
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for mark in overlays.breaks {
            let middle = (Double(mark.start) + Double(mark.end)) / 2
            let x = CGFloat((middle - viewport.center) * viewport.pointsPerSecond + viewport.widthPoints / 2)
            guard x > -labelWidth, x < width + labelWidth else { continue }
            if used == breakLayers.count {
                let layer = CATextLayer()
                layer.font = NSFont.systemFont(ofSize: 10, weight: .semibold)
                layer.fontSize = 10
                layer.alignmentMode = .center
                layer.foregroundColor = NSColor.white.withAlphaComponent(0.7).cgColor
                metalLayer.addSublayer(layer)
                breakLayers.append(layer)
            }
            let layer = breakLayers[used]
            used += 1
            layer.isHidden = false
            layer.contentsScale = metalLayer.contentsScale
            if layer.string as? String != mark.label { layer.string = mark.label }
            layer.frame = CGRect(x: x - labelWidth / 2, y: (bounds.height - height) / 2, width: labelWidth, height: height)
        }
        for layer in breakLayers.dropFirst(used) {
            layer.isHidden = true
        }
        CATransaction.commit()
    }

    /// Shapes for everything over the runs. There are few enough of these, and they change
    /// rarely enough, that plain paths are fine, and they stay crisp at any zoom.
    private func layoutOverlays(viewport: StripViewport) {
        func x(_ seconds: Float) -> CGFloat {
            CGFloat((Double(seconds) - viewport.center) * viewport.pointsPerSecond + viewport.widthPoints / 2)
        }
        let middle = bounds.height / 2
        let visible = -20...(CGFloat(viewport.widthPoints) + 20)

        let speech = CGMutablePath()
        for span in overlays.speech {
            let start = max(x(span.lowerBound), visible.lowerBound)
            let end = min(x(span.upperBound), visible.upperBound)
            guard end > start else { continue }
            speech.addRoundedRect(
                in: CGRect(x: start, y: middle - capsuleHeight / 2 - 6, width: max(end - start, 3), height: 3),
                cornerWidth: 1.5,
                cornerHeight: 1.5
            )
        }

        let stars = CGMutablePath()
        for star in overlays.stars {
            let position = x(star)
            guard visible.contains(position) else { continue }
            Self.addStar(to: stars, center: CGPoint(x: position, y: middle + capsuleHeight / 2 + 7), radius: 5)
        }

        let hover = CGMutablePath()
        if let hovered = overlays.hovered, overlays.selection == nil {
            let start = max(x(hovered.lowerBound), visible.lowerBound)
            let end = min(x(hovered.upperBound), visible.upperBound)
            if end > start {
                let height = capsuleHeight + 5
                hover.addRoundedRect(
                    in: CGRect(x: start - 2.5, y: middle - height / 2, width: end - start + 5, height: height),
                    cornerWidth: height / 2,
                    cornerHeight: height / 2
                )
            }
        }

        let selection = CGMutablePath()
        let handles = CGMutablePath()
        if let selected = overlays.selection {
            let start = x(selected.lowerBound)
            let end = x(selected.upperBound)
            let height = capsuleHeight + 15
            selection.addRoundedRect(
                in: CGRect(
                    x: max(start, visible.lowerBound),
                    y: middle - height / 2,
                    width: max(min(end, visible.upperBound) - max(start, visible.lowerBound), 2),
                    height: height
                ),
                cornerWidth: 6,
                cornerHeight: 6
            )
            for position in [start, end] where visible.contains(position) {
                handles.addRoundedRect(
                    in: CGRect(x: position - 2.5, y: middle - height / 2 - 3, width: 5, height: height + 6),
                    cornerWidth: 2.5,
                    cornerHeight: 2.5
                )
            }
        }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for shape in [speechLayer, starLayer, hoverLayer, selectionLayer, handleLayer] {
            shape.frame = metalLayer.bounds
        }
        speechLayer.path = speech
        starLayer.path = stars
        hoverLayer.path = hover
        selectionLayer.path = selection
        handleLayer.path = handles
        CATransaction.commit()
    }

    private static func addStar(to path: CGMutablePath, center: CGPoint, radius: CGFloat) {
        for point in 0..<10 {
            let angle = CGFloat(point) * .pi / 5 + .pi / 2
            let distance = point.isMultiple(of: 2) ? radius : radius * 0.45
            let position = CGPoint(x: center.x + cos(angle) * distance, y: center.y + sin(angle) * distance)
            if point == 0 {
                path.move(to: position)
            } else {
                path.addLine(to: position)
            }
        }
        path.closeSubpath()
    }

    /// Centres each icon on the visible part of its run, and leaves out any that wouldn't
    /// fit. These are plain layers, so moving them never touches SwiftUI.
    private func layoutIcons(viewport: StripViewport) {
        let positions = Self.iconPositions(for: icons, viewport: viewport, iconSize: Double(Self.iconSize))
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (index, position) in positions.enumerated() {
            if index == iconLayers.count {
                let layer = CALayer()
                layer.contentsGravity = .resizeAspect
                layer.contentsScale = metalLayer.contentsScale
                metalLayer.addSublayer(layer)
                iconLayers.append(layer)
            }
            let layer = iconLayers[index]
            layer.isHidden = false
            layer.contents = icons[position.icon].image
            layer.frame = CGRect(
                x: position.x - Self.iconSize / 2,
                y: (bounds.height - Self.iconSize) / 2,
                width: Self.iconSize,
                height: Self.iconSize
            )
        }
        for layer in iconLayers.dropFirst(positions.count) {
            layer.isHidden = true
        }
        CATransaction.commit()
    }

    /// Where icons go. Runs are in time order, so one pass avoids overlaps.
    static func iconPositions(
        for icons: [StripIcon],
        viewport: StripViewport,
        iconSize: Double
    ) -> [(icon: Int, x: CGFloat)] {
        var positions: [(icon: Int, x: CGFloat)] = []
        var lastEdge = -Double.infinity
        for (index, icon) in icons.enumerated() {
            let x0 = (Double(icon.start) - viewport.center) * viewport.pointsPerSecond + viewport.widthPoints / 2
            let x1 = (Double(icon.end) - viewport.center) * viewport.pointsPerSecond + viewport.widthPoints / 2
            let visibleStart = max(x0, 0)
            let visibleEnd = min(x1, viewport.widthPoints)
            guard visibleEnd - visibleStart >= iconSize else { continue }
            let center = (visibleStart + visibleEnd) / 2
            guard center - iconSize / 2 >= lastEdge + 2 else { continue }
            positions.append((index, CGFloat(center)))
            lastEdge = center + iconSize / 2
        }
        return positions
    }
}

/// The line that marks the moment on screen. It sits above the strip, and it's white
/// with a dark outline so it reads on any frame.
public final class PlayheadView: NSView {
    public override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.white.cgColor
        layer?.cornerRadius = 1.5
        layer?.borderColor = NSColor.black.withAlphaComponent(0.35).cgColor
        layer?.borderWidth = 0.5
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Not used") }

    public override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
