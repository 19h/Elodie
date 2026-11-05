import AppKit
import Metal
import QuartzCore
import StripRenderer

/// Hosts the strip renderer on a Metal layer.
public final class StripView: NSView, CALayerDelegate {
    private let device: any MTLDevice
    private let queue: any MTLCommandQueue
    private let metalLayer = CAMetalLayer()
    private let renderer: StripRenderer

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

    public func setRuns(_ runs: [StripRun]) {
        renderer.setRuns(runs)
    }

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
    }
}
