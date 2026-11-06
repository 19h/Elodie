import Metal
import simd

/// One capsule on the strip.
public struct StripRun: Equatable, Sendable {
    /// Start and end in seconds since the origin set with `setRuns`.
    public var start: Float
    public var end: Float
    public var color: SIMD4<Float>

    public init(start: Float, end: Float, color: SIMD4<Float>) {
        self.start = start
        self.end = end
        self.color = color
    }
}

/// What part of the timeline is visible.
public struct StripViewport: Equatable, Sendable {
    /// The time at the centre of the strip, in seconds since the origin.
    public var center: Double
    public var pointsPerSecond: Double
    public var widthPoints: Double
    public var heightPoints: Double
    public var capsuleHeightPoints: Double
    public var scale: Double

    public init(
        center: Double,
        pointsPerSecond: Double,
        widthPoints: Double,
        heightPoints: Double,
        capsuleHeightPoints: Double = 14,
        scale: Double = 2
    ) {
        self.center = center
        self.pointsPerSecond = pointsPerSecond
        self.widthPoints = widthPoints
        self.heightPoints = heightPoints
        self.capsuleHeightPoints = capsuleHeightPoints
        self.scale = scale
    }
}

/// Draws the timeline's capsules with a signed distance field, so edges stay crisp at
/// any size. Panning and zooming only change uniforms, so scrubbing never has to touch
/// the run data or cross into Rust.
public final class StripRenderer {
    private let device: any MTLDevice
    private let pipeline: any MTLRenderPipelineState
    private var instances: (any MTLBuffer)?
    private var instanceCount = 0

    private static let source = """
    #include <metal_stdlib>
    using namespace metal;

    struct Instance {
        float start;
        float end;
        float4 color;
    };

    struct Uniforms {
        float center;
        float pointsPerSecond;
        float2 sizePoints;
        float capsuleHeight;
        float scale;
    };

    struct Varyings {
        float4 position [[position]];
        float2 local;        // Points from the capsule's centre.
        float2 halfSize;
        float4 color;
    };

    vertex Varyings strip_vertex(uint vid [[vertex_id]],
                                 uint iid [[instance_id]],
                                 const device Instance *instances [[buffer(0)]],
                                 constant Uniforms &u [[buffer(1)]]) {
        Instance run = instances[iid];
        float2 corner = float2(vid & 1, (vid >> 1) & 1);

        float x0 = (run.start - u.center) * u.pointsPerSecond + u.sizePoints.x / 2;
        float x1 = (run.end - u.center) * u.pointsPerSecond + u.sizePoints.x / 2;
        // Even a very short run stays a visible dot.
        if (x1 - x0 < u.capsuleHeight) {
            float mid = (x0 + x1) / 2;
            x0 = mid - u.capsuleHeight / 2;
            x1 = mid + u.capsuleHeight / 2;
        }
        float2 halfSize = float2((x1 - x0) / 2, u.capsuleHeight / 2);
        float2 mid = float2((x0 + x1) / 2, u.sizePoints.y / 2);

        // Grown by a pixel so the antialiased edge isn't clipped.
        float2 grown = halfSize + 1.0;
        float2 point = mid + (corner * 2 - 1) * grown;

        Varyings out;
        out.position = float4(point.x / u.sizePoints.x * 2 - 1, 1 - point.y / u.sizePoints.y * 2, 0, 1);
        out.local = point - mid;
        out.halfSize = halfSize;
        out.color = run.color;
        return out;
    }

    fragment float4 strip_fragment(Varyings in [[stage_in]], constant Uniforms &u [[buffer(1)]]) {
        float radius = in.halfSize.y;
        float2 q = abs(in.local) - in.halfSize + radius;
        float distance = length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - radius;
        // About one device pixel of softness, in points.
        float coverage = clamp(0.5 - distance * u.scale, 0.0, 1.0);
        return float4(in.color.rgb * in.color.a * coverage, in.color.a * coverage);
    }
    """

    public init(device: any MTLDevice, pixelFormat: MTLPixelFormat) throws {
        self.device = device
        let library = try device.makeLibrary(source: Self.source, options: nil)
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "strip_vertex")
        descriptor.fragmentFunction = library.makeFunction(name: "strip_fragment")
        let attachment = descriptor.colorAttachments[0]!
        attachment.pixelFormat = pixelFormat
        attachment.isBlendingEnabled = true
        // Colours are already multiplied by coverage.
        attachment.sourceRGBBlendFactor = .one
        attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
        attachment.sourceAlphaBlendFactor = .one
        attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
    }

    /// Replaces the runs to draw.
    public func setRuns(_ runs: [StripRun]) {
        instanceCount = runs.count
        guard !runs.isEmpty else {
            instances = nil
            return
        }
        // The shader's struct aligns the colour to 16 bytes, as this one does.
        struct Instance {
            var start: Float
            var end: Float
            var padding: SIMD2<Float> = .zero
            var color: SIMD4<Float>
        }
        let packed = runs.map { Instance(start: $0.start, end: $0.end, color: $0.color) }
        instances = packed.withUnsafeBytes { bytes in
            device.makeBuffer(bytes: bytes.baseAddress!, length: bytes.count, options: .storageModeShared)
        }
    }

    /// Draws into a render pass.
    public func draw(in encoder: any MTLRenderCommandEncoder, viewport: StripViewport) {
        guard let instances, instanceCount > 0 else { return }
        struct Uniforms {
            var center: Float
            var pointsPerSecond: Float
            var sizePoints: SIMD2<Float>
            var capsuleHeight: Float
            var scale: Float
        }
        var uniforms = Uniforms(
            center: Float(viewport.center),
            pointsPerSecond: Float(viewport.pointsPerSecond),
            sizePoints: SIMD2(Float(viewport.widthPoints), Float(viewport.heightPoints)),
            capsuleHeight: Float(viewport.capsuleHeightPoints),
            scale: Float(viewport.scale)
        )
        encoder.setRenderPipelineState(pipeline)
        encoder.setVertexBuffer(instances, offset: 0, index: 0)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.size, index: 1)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.size, index: 1)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: instanceCount)
    }
}
