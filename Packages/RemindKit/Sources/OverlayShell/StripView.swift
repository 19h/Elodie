import AppKit
import Metal
import QuartzCore
import StripRenderer

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
        commands.present(drawable)
        commands.commit()
        layoutIcons(viewport: viewport)
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
