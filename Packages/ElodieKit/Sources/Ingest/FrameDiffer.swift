import CoreVideo
import Foundation
import Metal

/// The outcome of comparing a frame with the last stored one.
public struct FrameDifference: Sendable, Equatable {
    /// An estimate of how many full-resolution pixels changed.
    public var changedPixels: Int
    /// Whether every pixel is black, as on some lock and login screens.
    public var isBlack: Bool
    /// Whether there was nothing to compare against yet.
    public var isFirstFrame: Bool
}

public enum DifferError: Error {
    case noDevice
    case setupFailed
    case unsupportedPixelFormat(OSType)
    case textureFailed
    case gpuFailed(String)
}

/// Compares frames on the GPU.
///
/// The comparison is against the last *stored* frame, not the previous capture.
/// If it were the previous capture, a slow change that stays below the threshold
/// on every tick would never be stored at all.
///
/// It works at half resolution to reduce GPU work, on a copy it owns, so it never
/// pins one of capture's few buffers.
public final class FrameDiffer {
    private let device: any MTLDevice
    private let queue: any MTLCommandQueue
    private let pipeline: any MTLComputePipelineState
    private let textureCache: CVMetalTextureCache

    private var reference: (any MTLTexture)?
    private var candidate: (any MTLTexture)?
    private var hasReference = false

    /// Per-channel change needed for a pixel to count, as a fraction of full scale.
    public var channelThreshold: Float = 10.0 / 256.0

    private static let source = """
    #include <metal_stdlib>
    using namespace metal;

    struct Params {
        uint ignoreTop;
        uint hasReference;
        float threshold;
    };

    kernel void diff(texture2d<float, access::sample> luma [[texture(0)]],
                     texture2d<float, access::sample> chroma [[texture(1)]],
                     texture2d<float, access::read> reference [[texture(2)]],
                     texture2d<float, access::write> candidate [[texture(3)]],
                     device atomic_uint &changed [[buffer(0)]],
                     device atomic_uint &notBlack [[buffer(1)]],
                     constant Params &params [[buffer(2)]],
                     uint2 gid [[thread_position_in_grid]]) {
        constexpr sampler bilinear(coord::normalized, filter::linear, address::clamp_to_edge);
        float2 size = float2(candidate.get_width(), candidate.get_height());
        float2 uv = (float2(gid) + 0.5) / size;
        float y = luma.sample(bilinear, uv).r;
        float2 c = chroma.sample(bilinear, uv).rg;
        float4 current = float4(y, c, 1.0);
        candidate.write(current, gid);

        if (y > 0.02) {
            atomic_fetch_add_explicit(&notBlack, 1, memory_order_relaxed);
        }
        if (params.hasReference != 0 && gid.y >= params.ignoreTop) {
            float3 delta = abs(current.rgb - reference.read(gid).rgb);
            if (any(delta > params.threshold)) {
                atomic_fetch_add_explicit(&changed, 1, memory_order_relaxed);
            }
        }
    }
    """

    public init() throws {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            throw DifferError.noDevice
        }
        self.device = device
        self.queue = queue

        let library = try device.makeLibrary(source: Self.source, options: nil)
        guard let function = library.makeFunction(name: "diff") else {
            throw DifferError.setupFailed
        }
        pipeline = try device.makeComputePipelineState(function: function)

        var cache: CVMetalTextureCache?
        CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache)
        guard let cache else {
            throw DifferError.setupFailed
        }
        textureCache = cache
    }

    /// Forgets the reference, so the next frame counts as the first. Call when
    /// the display's configuration changes.
    public func reset() {
        hasReference = false
        reference = nil
        candidate = nil
    }

    /// Compares a bi-planar 4:2:0 frame with the reference. `completion` runs on
    /// a GPU thread and the caller never blocks.
    ///
    /// - Parameter ignoringTop: rows at the top to ignore, in full-resolution
    ///   pixels. The menu bar clock shouldn't count as a change.
    public func compare(
        _ pixelBuffer: CVPixelBuffer,
        ignoringTop: Int,
        completion: @escaping @Sendable (Result<FrameDifference, any Error>) -> Void
    ) {
        do {
            let width = CVPixelBufferGetWidth(pixelBuffer)
            let height = CVPixelBufferGetHeight(pixelBuffer)
            let format = CVPixelBufferGetPixelFormatType(pixelBuffer)
            guard format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
                    || format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange else {
                throw DifferError.unsupportedPixelFormat(format)
            }

            let halfWidth = max(1, width / 2)
            let halfHeight = max(1, height / 2)
            if candidate?.width != halfWidth || candidate?.height != halfHeight {
                reset()
                candidate = try makeTexture(width: halfWidth, height: halfHeight)
                reference = try makeTexture(width: halfWidth, height: halfHeight)
            }
            guard let candidate, let reference else {
                throw DifferError.textureFailed
            }

            let luma = try planeTexture(pixelBuffer, plane: 0, format: .r8Unorm, width: width, height: height)
            let chroma = try planeTexture(pixelBuffer, plane: 1, format: .rg8Unorm, width: width / 2, height: height / 2)

            guard let commands = queue.makeCommandBuffer(),
                  let encoder = commands.makeComputeCommandEncoder(),
                  let changed = device.makeBuffer(length: 4, options: .storageModeShared),
                  let notBlack = device.makeBuffer(length: 4, options: .storageModeShared)
            else {
                throw DifferError.setupFailed
            }

            struct Params {
                var ignoreTop: UInt32
                var hasReference: UInt32
                var threshold: Float
            }
            var params = Params(
                ignoreTop: UInt32(ignoringTop / 2),
                hasReference: hasReference ? 1 : 0,
                threshold: channelThreshold
            )

            encoder.setComputePipelineState(pipeline)
            encoder.setTexture(CVMetalTextureGetTexture(luma.texture), index: 0)
            encoder.setTexture(CVMetalTextureGetTexture(chroma.texture), index: 1)
            encoder.setTexture(reference, index: 2)
            encoder.setTexture(candidate, index: 3)
            encoder.setBuffer(changed, offset: 0, index: 0)
            encoder.setBuffer(notBlack, offset: 0, index: 1)
            encoder.setBytes(&params, length: MemoryLayout<Params>.size, index: 2)
            encoder.dispatchThreads(
                MTLSize(width: halfWidth, height: halfHeight, depth: 1),
                threadsPerThreadgroup: MTLSize(
                    width: pipeline.threadExecutionWidth,
                    height: 1,
                    depth: 1
                )
            )
            encoder.endEncoding()

            let isFirst = !hasReference
            // Holding the CVMetalTextures keeps the frame's memory alive until
            // the GPU has finished with it. They need their cache when they're
            // released, and this differ may be gone by then, so it's held too, last
            // so that it outlives them.
            let keepAlive = UncheckedBox((luma, chroma, changed, notBlack, textureCache))
            commands.addCompletedHandler { buffer in
                if let error = buffer.error {
                    completion(.failure(DifferError.gpuFailed(error.localizedDescription)))
                    return
                }
                let (_, _, changed, notBlack, _) = keepAlive.value
                let changedCount = changed.contents().load(as: UInt32.self)
                let notBlackCount = notBlack.contents().load(as: UInt32.self)
                completion(.success(FrameDifference(
                    // Each half-resolution pixel stands for four full ones.
                    changedPixels: Int(changedCount) * 4,
                    isBlack: notBlackCount == 0,
                    isFirstFrame: isFirst
                )))
            }
            commands.commit()
        } catch {
            completion(.failure(error))
        }
    }

    /// Makes the frame from the latest `compare` the new reference. Call only for
    /// frames being stored, after that `compare` has completed.
    public func commitCandidate() {
        swap(&reference, &candidate)
        hasReference = true
    }

    private func makeTexture(width: Int, height: Int) throws -> any MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm,
            width: width,
            height: height,
            mipmapped: false
        )
        descriptor.usage = [.shaderRead, .shaderWrite]
        descriptor.storageMode = .private
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            throw DifferError.textureFailed
        }
        return texture
    }

    private struct PlaneTexture {
        let texture: CVMetalTexture
    }

    private func planeTexture(
        _ pixelBuffer: CVPixelBuffer,
        plane: Int,
        format: MTLPixelFormat,
        width: Int,
        height: Int
    ) throws -> PlaneTexture {
        var texture: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, textureCache, pixelBuffer, nil, format, width, height, plane, &texture
        )
        guard status == kCVReturnSuccess, let texture else {
            throw DifferError.textureFailed
        }
        return PlaneTexture(texture: texture)
    }
}

/// Carries values that aren't `Sendable` but are only used after the GPU is done.
private final class UncheckedBox<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}
