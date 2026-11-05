import CoreAPI
import CoreLive
import CoreVideo
import FrameEngine
import Foundation
import Ingest
import TestKit
import Testing

/// Collects encoder output, which arrives on another thread.
private final class Collector: @unchecked Sendable {
    private let lock = NSLock()
    private var frames: [EncodedFrame] = []
    private var failures: [any Error] = []

    func add(_ result: Result<EncodedFrame, any Error>) {
        lock.withLock {
            switch result {
            case .success(let frame): frames.append(frame)
            case .failure(let error): failures.append(error)
            }
        }
    }

    var collected: (frames: [EncodedFrame], failures: [any Error]) {
        lock.withLock { (frames, failures) }
    }
}

private func compare(
    _ differ: FrameDiffer,
    _ buffer: CVPixelBuffer,
    ignoringTop: Int = 0
) async throws -> FrameDifference {
    try await withCheckedThrowingContinuation { continuation in
        differ.compare(buffer, ignoringTop: ignoringTop) { continuation.resume(with: $0) }
    }
}

/// A flat bi-planar frame, optionally with a rectangle of a different luma.
private func flatFrame(
    width: Int = 640,
    height: Int = 400,
    luma: UInt8,
    rect: (x: Int, y: Int, width: Int, height: Int)? = nil,
    rectLuma: UInt8 = 255
) -> CVPixelBuffer {
    var buffer: CVPixelBuffer?
    let attributes: [CFString: Any] = [
        kCVPixelBufferIOSurfacePropertiesKey: [String: Any](),
        kCVPixelBufferMetalCompatibilityKey: true,
    ]
    CVPixelBufferCreate(
        kCFAllocatorDefault, width, height, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
        attributes as CFDictionary, &buffer
    )
    let frame = buffer!
    CVPixelBufferLockBaseAddress(frame, [])
    let y = CVPixelBufferGetBaseAddressOfPlane(frame, 0)!.assumingMemoryBound(to: UInt8.self)
    let yStride = CVPixelBufferGetBytesPerRowOfPlane(frame, 0)
    memset(y, Int32(luma), yStride * height)
    let c = CVPixelBufferGetBaseAddressOfPlane(frame, 1)!
    memset(c, 128, CVPixelBufferGetBytesPerRowOfPlane(frame, 1) * height / 2)
    if let rect {
        for row in rect.y..<(rect.y + rect.height) {
            memset(y + row * yStride + rect.x, Int32(rectLuma), rect.width)
        }
    }
    CVPixelBufferUnlockBaseAddress(frame, [])
    return frame
}

@Suite struct Differ {
    @Test func theFirstFrameHasNothingToCompareWith() async throws {
        let differ = try FrameDiffer()
        let result = try await compare(differ, flatFrame(luma: 100))
        #expect(result.isFirstFrame)
        #expect(result.changedPixels == 0)
    }

    @Test func anIdenticalFrameShowsNoChange() async throws {
        let differ = try FrameDiffer()
        _ = try await compare(differ, flatFrame(luma: 100))
        differ.commitCandidate()
        let result = try await compare(differ, flatFrame(luma: 100))
        #expect(!result.isFirstFrame)
        #expect(result.changedPixels == 0)
    }

    @Test func aChangedRegionIsCountedAtRoughlyItsSize() async throws {
        let differ = try FrameDiffer()
        _ = try await compare(differ, flatFrame(luma: 50))
        differ.commitCandidate()
        let rect = (x: 100, y: 100, width: 100, height: 40)
        let result = try await compare(differ, flatFrame(luma: 50, rect: rect))
        // 4,000 real pixels, measured at half resolution, so allow for the edges.
        #expect(abs(result.changedPixels - 4000) < 800)
    }

    @Test func changesInTheIgnoredTopRowsDoNotCount() async throws {
        let differ = try FrameDiffer()
        _ = try await compare(differ, flatFrame(luma: 50))
        differ.commitCandidate()
        let clock = flatFrame(luma: 50, rect: (x: 500, y: 4, width: 100, height: 20))
        let result = try await compare(differ, clock, ignoringTop: 52)
        #expect(result.changedPixels == 0)
    }

    /// The bug in the reference app: comparing with the previous capture means a
    /// slow change that stays under the threshold on every tick is never stored.
    @Test func slowDriftEventuallyCountsBecauseTheReferenceIsTheLastStoredFrame() async throws {
        let differ = try FrameDiffer()
        _ = try await compare(differ, flatFrame(luma: 100))
        differ.commitCandidate()

        // Each step is only 4/255, below the 10/256 threshold.
        var triggeredAt: UInt8?
        for step in 1...6 {
            let luma = 100 + UInt8(step * 4)
            let result = try await compare(differ, flatFrame(luma: luma))
            if result.changedPixels > 1000 {
                triggeredAt = luma
                break
            }
        }
        #expect(triggeredAt != nil, "a slow change was never noticed")
        // It must not trigger on the first step, or this proves nothing.
        #expect(triggeredAt != 104)
    }

    @Test func discardedFramesDoNotMoveTheReference() async throws {
        let differ = try FrameDiffer()
        _ = try await compare(differ, flatFrame(luma: 100))
        differ.commitCandidate()
        // Compared but not committed.
        _ = try await compare(differ, flatFrame(luma: 200))
        let result = try await compare(differ, flatFrame(luma: 100))
        #expect(result.changedPixels == 0)
    }

    @Test func blackFramesAreRecognised() async throws {
        let differ = try FrameDiffer()
        #expect(try await compare(differ, flatFrame(luma: 0)).isBlack)
        #expect(try await !compare(differ, flatFrame(luma: 0, rect: (x: 10, y: 10, width: 20, height: 20))).isBlack)
    }

    @Test func aNewSizeStartsOver() async throws {
        let differ = try FrameDiffer()
        _ = try await compare(differ, flatFrame(luma: 100))
        differ.commitCandidate()
        let result = try await compare(differ, flatFrame(width: 800, height: 600, luma: 100))
        #expect(result.isFirstFrame)
    }
}

@Suite struct EncodeAndDecode {
    private func encodeFrames(
        _ count: Int,
        settings: EncoderSettings,
        forceKeyframeAt: Set<Int> = []
    ) throws -> (frames: [EncodedFrame], sources: [SyntheticScreen.Frame]) {
        let screen = SyntheticScreen(width: settings.width, height: settings.height)
        let encoder = try HEVCEncoder(settings: settings)
        let collector = Collector()
        var sources: [SyntheticScreen.Frame] = []
        for i in 0..<count {
            let frame = screen.nextFrame()
            sources.append(frame)
            encoder.encode(frame.pixelBuffer, forceKeyframe: forceKeyframeAt.contains(i)) { collector.add($0) }
        }
        try encoder.finish()
        let (frames, failures) = collector.collected
        #expect(failures.isEmpty, "\(failures)")
        return (frames, sources)
    }

    private let small = EncoderSettings(width: 1280, height: 800, keyframeInterval: 10, rate: .quality(0.7))

    @Test func outputArrivesInOrderWithTheRequestedKeyframeSpacing() throws {
        let (frames, _) = try encodeFrames(25, settings: small)
        #expect(frames.count == 25)
        #expect(frames[0].isKeyframe)
        let keyframes = frames.indices.filter { frames[$0].isKeyframe }
        for (a, b) in zip(keyframes, keyframes.dropFirst()) {
            #expect(b - a <= 10)
        }
        #expect(keyframes.count >= 3)
    }

    /// A frame held inside the encoder is lost in a crash, at 2 seconds per frame.
    /// The hardware encoder rejects MaxFrameDelayCount, so this checks the behaviour
    /// directly: each frame comes out without waiting for a later one.
    @Test func framesAreNotHeldBackByTheEncoder() async throws {
        let screen = SyntheticScreen(width: small.width, height: small.height)
        let encoder = try HEVCEncoder(settings: small)
        let collector = Collector()
        for i in 0..<20 {
            encoder.encode(screen.nextFrame().pixelBuffer) { collector.add($0) }
            // Far longer than a frame takes, but short of the next capture.
            var waited = 0
            while collector.collected.frames.count <= i && waited < 200 {
                try await Task.sleep(for: .milliseconds(5))
                waited += 1
            }
            #expect(collector.collected.frames.count == i + 1, "frame \(i) is stuck in the encoder")
        }
    }

    @Test func aForcedKeyframeIsHonoured() throws {
        let (frames, _) = try encodeFrames(8, settings: small, forceKeyframeAt: [5])
        #expect(frames[5].isKeyframe)
    }

    /// Every frame has to decode back to the right picture, and the barcode proves
    /// which one it is. Decoding starts at a keyframe, as seeking does.
    @Test func everyFrameDecodesToTheRightPicture() throws {
        let (frames, sources) = try encodeFrames(25, settings: small)
        let decoder = try HEVCDecoder(parameterSets: frames[0].parameterSets, width: small.width, height: small.height)
        let screen = SyntheticScreen(width: small.width, height: small.height)
        for (index, frame) in frames.enumerated() {
            let image = try decoder.decode(frame.data)
            #expect(FrameBarcode.read(from: image, originY: screen.barcodeY) == sources[index].index)
            #expect(CVPixelBufferGetWidth(image) == small.width)
        }
    }

    @Test func theSyntheticScreenIsRepeatable() {
        let a = SyntheticScreen(width: 640, height: 400, seed: 9)
        let b = SyntheticScreen(width: 640, height: 400, seed: 9)
        for _ in 0..<5 {
            #expect(a.nextFrame().words == b.nextFrame().words)
        }
    }

    /// Encode, store through the real log, read back, and decode.
    @Test func framesSurviveTheWholePathThroughTheVault() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "remind-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let (frames, sources) = try encodeFrames(25, settings: small)
        let core = try LiveCore(vaultDirectory: directory, masterKey: Data(repeating: 3, count: 32))
        let display = UUID()
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        for (index, frame) in frames.enumerated() {
            let outcome = try core.append(EncodedSample(
                displayID: display,
                width: small.width,
                height: small.height,
                parameterSets: frame.parameterSets,
                capturedAt: start.addingTimeInterval(Double(index) * 2),
                monotonicNanoseconds: UInt64(index),
                isKeyframe: frame.isKeyframe,
                context: FrameContext(bundleID: "com.example"),
                data: frame.data
            ))
            #expect(outcome == .accepted)
            try await Task.sleep(for: .milliseconds(15))
        }
        try core.sealAll()
        try await Task.sleep(for: .milliseconds(1200))

        // Seek to frame 17: it has to come back through a keyframe at or before it.
        let target = start.addingTimeInterval(17 * 2)
        let found = try #require(try core.lookup(display: display, at: target))
        let group = try core.readGroup(containing: found.id)
        #expect(group.samples[0].isKeyframe)

        let decoder = try HEVCDecoder(parameterSets: group.parameterSets, width: group.width, height: group.height)
        var image: CVPixelBuffer?
        for sample in group.samples[...group.target] {
            image = try decoder.decode(sample.data)
        }
        let barcodeY = SyntheticScreen(width: small.width, height: small.height).barcodeY
        #expect(FrameBarcode.read(from: try #require(image), originY: barcodeY) == sources[17].index)
    }
}
