import Capture
import CoreAPI
import CoreFake
import CoreLive
import CoreVideo
import FrameEngine
import Foundation
import Ingest
import TestKit
import Testing

private func capture(_ buffer: CVPixelBuffer, at seconds: TimeInterval = 0) -> CapturedFrame {
    CapturedFrame(
        pixelBuffer: buffer,
        displayID: 1,
        capturedAt: Date(timeIntervalSince1970: 1_800_000_000 + seconds),
        windows: [],
        menuBarRows: 0
    )
}

/// Feeds a frame and waits for the pipeline to finish with it.
private func feed(_ pipeline: DisplayPipeline, _ frame: CapturedFrame) async throws {
    pipeline.queue.async { pipeline.ingest(frame) }
    // The work hops between the queue, the GPU, and the encoder.
    for _ in 0..<400 {
        let stats = pipeline.stats
        let settled = stats.busy + stats.unchanged + stats.black + stats.excluded
            + stats.encodeFailed + stats.appendRefused + stats.stored
        if settled >= stats.received, stats.received > 0 {
            return
        }
        try await Task.sleep(for: .milliseconds(5))
    }
    Issue.record("the pipeline didn't finish with a frame")
}

private func keepAll(_: CapturedFrame) -> FrameDecision {
    .keep(FrameContext(bundleID: "com.example"))
}

/// Any change counts. At these small sizes, typing one word can change fewer pixels
/// than the real threshold, and these tests are about what happens to changed frames.
private var anyChange: PipelineSettings {
    var settings = PipelineSettings()
    settings.changedPixelThreshold = 1
    return settings
}

@Suite struct Pipeline {
    @Test func theFirstFrameIsStoredAsAKeyframe() async throws {
        let core = FakeCore()
        let display = UUID()
        let pipeline = try DisplayPipeline(core: core, displayUUID: display, decide: keepAll)
        let screen = SyntheticScreen(width: 640, height: 400)
        try await feed(pipeline, capture(screen.nextFrame().pixelBuffer))
        #expect(pipeline.stats.stored == 1)
        let frame = try #require(try core.lookup(display: display, at: Date(timeIntervalSince1970: 1_900_000_000)))
        #expect(try core.readGroup(containing: frame.id).samples[0].isKeyframe)
    }

    @Test func anUnchangedFrameIsNotStored() async throws {
        let core = FakeCore()
        let pipeline = try DisplayPipeline(core: core, displayUUID: UUID(), decide: keepAll)
        let frame = SyntheticScreen(width: 640, height: 400).nextFrame()
        try await feed(pipeline, capture(frame.pixelBuffer))
        try await feed(pipeline, capture(frame.pixelBuffer, at: 2))
        #expect(pipeline.stats.stored == 1)
        #expect(pipeline.stats.unchanged == 1)
    }

    @Test func aChangedFrameIsStored() async throws {
        let core = FakeCore()
        let pipeline = try DisplayPipeline(core: core, displayUUID: UUID(), settings: anyChange, decide: keepAll)
        let screen = SyntheticScreen(width: 640, height: 400)
        try await feed(pipeline, capture(screen.nextFrame().pixelBuffer))
        try await feed(pipeline, capture(screen.nextFrame().pixelBuffer, at: 2))
        #expect(pipeline.stats.stored == 2)
    }

    @Test func aDroppedFrameIsNotStoredAndTheChangeIsStillNoticedAfterwards() async throws {
        let core = FakeCore()
        final class Toggle: @unchecked Sendable {
            let lock = NSLock()
            var allow = true
        }
        let toggle = Toggle()
        let pipeline = try DisplayPipeline(core: core, displayUUID: UUID(), settings: anyChange) { _ in
            toggle.lock.withLock { toggle.allow } ? .keep(FrameContext()) : .drop(reason: "private")
        }
        let screen = SyntheticScreen(width: 640, height: 400)
        let (first, second) = (screen.nextFrame(), screen.nextFrame())

        try await feed(pipeline, capture(first.pixelBuffer))
        toggle.lock.withLock { toggle.allow = false }
        try await feed(pipeline, capture(second.pixelBuffer, at: 2))
        #expect(pipeline.stats.excluded == 1)
        #expect(pipeline.stats.stored == 1)

        // Once allowed, the same picture still counts as changed, because the
        // reference didn't move when the frame was dropped.
        toggle.lock.withLock { toggle.allow = true }
        try await feed(pipeline, capture(second.pixelBuffer, at: 4))
        #expect(pipeline.stats.stored == 2)
    }

    /// Small edits add up, because the comparison is against what's stored.
    @Test func smallChangesAccumulateUntilTheyCrossTheThreshold() async throws {
        let core = FakeCore()
        var settings = PipelineSettings()
        settings.changedPixelThreshold = 3000
        let pipeline = try DisplayPipeline(core: core, displayUUID: UUID(), settings: settings, decide: keepAll)
        // A growing bar: each step alone is far below the threshold.
        func bar(_ width: Int) -> CVPixelBuffer {
            TestFrames.flat(width: 640, height: 400, luma: 40, rect: (x: 0, y: 200, width: width, height: 20), rectLuma: 220)
        }
        try await feed(pipeline, capture(bar(0)))
        #expect(pipeline.stats.stored == 1)
        var firstStoredAgainAt: Int?
        for step in 1...20 {
            try await feed(pipeline, capture(bar(step * 10), at: Double(step)))
            if pipeline.stats.stored == 2, firstStoredAgainAt == nil {
                firstStoredAgainAt = step
            }
        }
        // 200 pixels per step, so a stored frame needs about 15 steps.
        let step = try #require(firstStoredAgainAt, "accumulated change was never stored")
        #expect((10...20).contains(step))
    }

    @Test func keepingTheNextFrameBypassesTheChangeCheck() async throws {
        let core = FakeCore()
        let pipeline = try DisplayPipeline(core: core, displayUUID: UUID(), decide: keepAll)
        let frame = SyntheticScreen(width: 640, height: 400).nextFrame()
        try await feed(pipeline, capture(frame.pixelBuffer))
        pipeline.keepNextFrame()
        try await feed(pipeline, capture(frame.pixelBuffer, at: 2))
        #expect(pipeline.stats.stored == 2)
        // Only one frame was forced.
        try await feed(pipeline, capture(frame.pixelBuffer, at: 4))
        #expect(pipeline.stats.stored == 2)
    }

    /// Frames from the pipeline, through the real vault, back through the decoder.
    @Test func recordedFramesPlayBackCorrectly() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "elodie-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let core = try LiveCore(vaultDirectory: directory, masterKey: Data(repeating: 3, count: 32))
        let display = UUID()
        let pipeline = try DisplayPipeline(core: core, displayUUID: display, settings: anyChange, decide: keepAll)
        let screen = SyntheticScreen(width: 1280, height: 800)
        var indices: [Int] = []
        for tick in 0..<12 {
            let frame = screen.nextFrame()
            indices.append(frame.index)
            try await feed(pipeline, capture(frame.pixelBuffer, at: Double(tick) * 2))
            while core.stats().loggedFrames <= UInt64(tick) {
                try await Task.sleep(for: .milliseconds(2))
            }
        }
        #expect(pipeline.stats.stored == 12)
        try core.sealAll()
        try await Task.sleep(for: .milliseconds(1200))

        let target = Date(timeIntervalSince1970: 1_800_000_000 + 7 * 2)
        let found = try #require(try core.lookup(display: display, at: target))
        let group = try core.readGroup(containing: found.id)
        let decoder = try HEVCDecoder(parameterSets: group.parameterSets, width: group.width, height: group.height)
        var image: CVPixelBuffer?
        for sample in group.samples[...group.target] {
            image = try decoder.decode(sample.data)
        }
        let decoded = try #require(image)
        #expect(FrameBarcode.read(from: decoded, originY: screen.barcodeY) == indices[7])
    }
}
