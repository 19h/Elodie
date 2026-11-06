import CoreAPI
import CoreFake
import CoreLive
import CoreVideo
import Foundation
@testable import FrameEngine
import TestKit
import Testing

/// Collects what the engine shows.
private final class Updates: @unchecked Sendable {
    private let lock = NSLock()
    private var all: [ScrubUpdate] = []

    func add(_ update: ScrubUpdate) { lock.withLock { all.append(update) } }
    var list: [ScrubUpdate] { lock.withLock { all } }
    var last: ScrubUpdate? { lock.withLock { all.last } }
    func clear() { lock.withLock { all.removeAll() } }
}

private func fixture(count: Int = 70) async throws -> (LiveCore, FixtureVault.Recording, URL) {
    let directory = FileManager.default.temporaryDirectory
        .appending(path: "elodie-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let core = try LiveCore(vaultDirectory: directory, masterKey: Data(repeating: 3, count: 32))
    let recording = try await FixtureVault.record(into: core, width: 1280, height: 800, count: count, keyframeInterval: 30)
    return (core, recording, directory)
}

private func barcode(_ update: ScrubUpdate?, _ recording: FixtureVault.Recording) throws -> Int {
    let buffer = try #require(update?.frame.buffer)
    return try #require(FrameBarcode.read(from: buffer, originY: recording.barcodeY))
}

/// Waits for settling work to finish. Settling is only scheduled once the requests have
/// been worked through, however long that takes, so that has to finish before the wait
/// for it starts.
private func settle(_ engine: ScrubEngine) async throws {
    engine.waitUntilIdle()
    try await Task.sleep(for: .milliseconds(300))
    engine.waitUntilIdle()
}

@Suite struct Scrubbing {
    @Test func seekingShowsExactlyTheFrameAtThatTime() async throws {
        let (core, recording, directory) = try await fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let engine = ScrubEngine(core: core, display: recording.display)
        let updates = Updates()
        engine.onUpdate = { updates.add($0) }

        for index in [0, 17, 29, 30, 31, 45, 69] {
            engine.seek(.init(time: recording.time(of: index), velocity: 0))
            engine.waitUntilIdle()
            #expect(try barcode(updates.last, recording) == index)
            #expect(updates.last?.isExact == true)
        }
    }

    @Test func aTimeBetweenFramesShowsTheOneBefore() async throws {
        let (core, recording, directory) = try await fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let engine = ScrubEngine(core: core, display: recording.display)
        let updates = Updates()
        engine.onUpdate = { updates.add($0) }
        engine.seek(.init(time: recording.time(of: 12).addingTimeInterval(1.5), velocity: 0))
        engine.waitUntilIdle()
        #expect(try barcode(updates.last, recording) == 12)
    }

    /// The hard case: every step back needs earlier frames, which P-frames can only
    /// get from a keyframe. Every frame still has to be the right one.
    @Test func steppingBackwardFrameByFrameIsExactAcrossGroups() async throws {
        let (core, recording, directory) = try await fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let engine = ScrubEngine(core: core, display: recording.display)
        let updates = Updates()
        engine.onUpdate = { updates.add($0) }
        for index in stride(from: 45, through: 20, by: -1) {
            engine.seek(.init(time: recording.time(of: index), velocity: -1))
            engine.waitUntilIdle()
            let last = try #require(updates.last)
            #expect(last.isExact)
            #expect(try barcode(last, recording) == index)
        }
    }

    @Test func steppingForwardReusesTheOpenDecoderAndIsExact() async throws {
        let (core, recording, directory) = try await fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let engine = ScrubEngine(core: core, display: recording.display)
        let updates = Updates()
        engine.onUpdate = { updates.add($0) }
        for index in 5...40 {
            engine.seek(.init(time: recording.time(of: index), velocity: 1))
            engine.waitUntilIdle()
            #expect(try barcode(updates.last, recording) == index)
        }
    }

    /// Requests far outrun decoding here. The engine must skip ahead instead of
    /// working through a backlog, and end on the last one asked for.
    @Test func aFloodOfRequestsEndsOnTheLastOne() async throws {
        let (core, recording, directory) = try await fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let engine = ScrubEngine(core: core, display: recording.display)
        let updates = Updates()
        engine.onUpdate = { updates.add($0) }
        for index in stride(from: 69, through: 3, by: -1) {
            engine.seek(.init(time: recording.time(of: index), velocity: -500))
        }
        try await settle(engine)
        #expect(try barcode(updates.last, recording) == 3)
        #expect(updates.last?.isExact == true)
        // It got there without showing every frame along the way.
        #expect(updates.list.count < 67)
    }

    @Test func scrubbingFastShowsKeyframesThenSettlesOnTheExactFrame() async throws {
        let (core, recording, directory) = try await fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let engine = ScrubEngine(core: core, display: recording.display)
        let updates = Updates()
        engine.onUpdate = { updates.add($0) }

        engine.seek(.init(time: recording.time(of: 47), velocity: 10_000))
        engine.waitUntilIdle()
        // Frame 47's group starts at a keyframe at or before it.
        let keyframeShown = try barcode(updates.list.first, recording)
        #expect(keyframeShown <= 47)
        #expect(updates.list.first?.isExact == false || keyframeShown == 47)

        try await settle(engine)
        #expect(try barcode(updates.last, recording) == 47)
        #expect(updates.last?.isExact == true)
    }

    @Test func afterSettlingTheNeighboursAreAlreadyDecoded() async throws {
        let (core, recording, directory) = try await fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let engine = ScrubEngine(core: core, display: recording.display)
        let updates = Updates()
        engine.onUpdate = { updates.add($0) }
        engine.seek(.init(time: recording.time(of: 35), velocity: 0))
        try await settle(engine)
        updates.clear()

        // Both directions should now be instant, and instant means exact on the first update.
        for index in [34, 36, 30, 29, 28] {
            engine.seek(.init(time: recording.time(of: index), velocity: 0))
            engine.waitUntilIdle()
            #expect(updates.last?.isExact == true)
            #expect(try barcode(updates.last, recording) == index)
        }
    }

    /// A settle that's already been scheduled when a new request arrives mustn't drag
    /// the picture back. This repeats because the window for the race is narrow.
    @Test func aLateSettleNeverJumpsBackToAnOldFrame() async throws {
        let (core, recording, directory) = try await fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let engine = ScrubEngine(core: core, display: recording.display)
        let updates = Updates()
        engine.onUpdate = { updates.add($0) }
        for round in 0..<40 {
            let first = 10 + round % 20
            let second = 40 + round % 20
            engine.seek(.init(time: recording.time(of: first), velocity: 0))
            engine.waitUntilIdle()
            engine.seek(.init(time: recording.time(of: second), velocity: 0))
            engine.waitUntilIdle()
            // Long enough for any stale settle to fire.
            try await Task.sleep(for: .milliseconds(80))
            engine.waitUntilIdle()
            #expect(try barcode(updates.last, recording) == second, "round \(round)")
        }
    }

    @Test func aTimeBeforeTheFirstFrameShowsNothing() async throws {
        let (core, recording, directory) = try await fixture(count: 5)
        defer { try? FileManager.default.removeItem(at: directory) }
        let engine = ScrubEngine(core: core, display: recording.display)
        let updates = Updates()
        engine.onUpdate = { updates.add($0) }
        engine.seek(.init(time: recording.start.addingTimeInterval(-100), velocity: 0))
        engine.waitUntilIdle()
        #expect(updates.list.isEmpty)
    }
}

@Suite struct Caching {
    private func frame(_ id: Int64, bytes: Int = 1000) -> DecodedFrame {
        var buffer: CVPixelBuffer?
        // 4:2:0 is 1.5 bytes a pixel, so this is `bytes` in total.
        let side = Int((Double(bytes) / 1.5).squareRoot())
        CVPixelBufferCreate(
            kCFAllocatorDefault, side, side,
            kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, nil, &buffer
        )
        return DecodedFrame(frameID: id, capturedAt: Date(), buffer: buffer!)
    }

    @Test func theBudgetIsNeverExceeded() {
        let cache = FrameCache(budget: 10_000)
        for id in 0..<100 {
            cache.insert(frame(Int64(id)), target: Int64(id), direction: 1)
            #expect(cache.byteCount <= 10_000)
        }
    }

    @Test func theFarthestFramesGoFirst() {
        let unit = frame(0).byteCount
        let cache = FrameCache(budget: unit * 3)
        for id in [0, 50, 100] as [Int64] {
            cache.insert(frame(id), target: 50, direction: 0)
        }
        cache.insert(frame(60), target: 50, direction: 0)
        #expect(cache.frame(0) == nil || cache.frame(100) == nil)
        #expect(cache.frame(50) != nil)
        #expect(cache.frame(60) != nil)
    }

    @Test func framesAheadOfTravelOutliveFramesBehind() {
        let unit = frame(0).byteCount
        let cache = FrameCache(budget: unit * 3)
        // Moving forward, so at equal distance the one behind goes.
        for id in [40, 50, 60] as [Int64] {
            cache.insert(frame(id), target: 50, direction: 1)
        }
        cache.insert(frame(51), target: 50, direction: 1)
        #expect(cache.frame(40) == nil)
        #expect(cache.frame(60) != nil)
    }

    @Test func thePinnedFrameIsNeverEvicted() {
        let unit = frame(0).byteCount
        let cache = FrameCache(budget: unit * 2)
        cache.insert(frame(0), target: 0, direction: 0)
        cache.pin([0])
        for id in 1...20 as ClosedRange<Int64> {
            cache.insert(frame(id), target: id, direction: 1)
        }
        #expect(cache.frame(0) != nil)
    }

    @Test func theFallbackNeverMovesAwayFromTheTarget() {
        let cache = FrameCache(budget: 1_000_000)
        for id in [10, 20, 30] as [Int64] {
            cache.insert(frame(id), target: 0, direction: 0)
        }
        #expect(cache.nearest(to: 22, notBehind: nil)?.frameID == 20)
        // 25 is already showing, and 20 is farther from 26 than that is.
        #expect(cache.nearest(to: 26, notBehind: 25)?.frameID == nil || cache.nearest(to: 26, notBehind: 25)?.frameID == 30)
        // Already exactly there, so there's nothing better.
        #expect(cache.nearest(to: 20, notBehind: 20) == nil)
    }

    @Test(arguments: [
        (UInt64(8_000_000_000), 800_000_000),
        (UInt64(4_000_000_000), 700_000_000),
        (UInt64(137_000_000_000), 1_400_000_000),
    ])
    func theBudgetScalesWithMemoryWithinLimits(memory: UInt64, expected: Int) {
        #expect(ScrubEngine.defaultBudget(physicalMemory: memory) == expected)
    }
}

import AVFoundation

@Suite struct Exporting {
    @Test func aClipIsAPlayableVideoOfTheRightFrames() async throws {
        let (core, recording, directory) = try await fixture(count: 40)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "clip.mp4")

        let summary = try await MP4Exporter.export(
            core: core,
            display: recording.display,
            from: recording.time(of: 5),
            to: recording.time(of: 34),
            to: url
        )
        // Frames 5 to 34 play. The keyframe before 5 is in the file too, so 5 can decode.
        #expect(summary.frames == 30)
        #expect(summary.stoppedEarlyAt == nil)

        let asset = AVURLAsset(url: url)
        let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let size = try await track.load(.naturalSize)
        #expect(size.width == 1280 && size.height == 800)
        // 30 frames, 2 seconds apart, with the last held briefly: the stretch ends on it.
        let duration = try await asset.load(.duration).seconds
        #expect(abs(duration - 59) < 1.5, "duration \(duration)")

        // AVFoundation can read it back, and the barcode proves it's the right frame.
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
        ])
        reader.add(output)
        #expect(reader.startReading())
        var numbers: [Int] = []
        while let sample = output.copyNextSampleBuffer() {
            guard let image = CMSampleBufferGetImageBuffer(sample) else { continue }
            if let number = FrameBarcode.read(from: image, originY: recording.barcodeY) {
                numbers.append(number)
            }
        }
        // The file holds what it needs to decode, and plays only what was asked for.
        let played = numbers.filter { $0 >= 5 }
        #expect(played == Array(5..<35))
        #expect(numbers.count == played.count || numbers.prefix(5) == [0, 1, 2, 3, 4])
    }

    /// Only keyframes are marked as places to seek to, so seeking shows the right picture.
    @Test func framesThatNeedOthersAreMarked() async throws {
        let (core, recording, directory) = try await fixture(count: 40)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "clip.mp4")
        try await MP4Exporter.export(
            core: core, display: recording.display,
            from: recording.time(of: 0), to: recording.time(of: 39), to: url
        )
        let asset = AVURLAsset(url: url)
        let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        reader.add(output)
        #expect(reader.startReading())
        var sync = 0, total = 0
        while let sample = output.copyNextSampleBuffer() {
            guard CMSampleBufferGetNumSamples(sample) > 0 else { continue }
            total += 1
            let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]]
            if attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool != true { sync += 1 }
        }
        #expect(total == 40)
        #expect(sync < total / 2, "\(sync) of \(total) were marked as keyframes")
    }

    /// A failed export can't cost someone the file they chose to replace.
    @Test func aFailedExportLeavesTheOldFileAlone() async throws {
        let (core, recording, directory) = try await fixture(count: 3)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "clip.mp4")
        try Data("keep me".utf8).write(to: url)
        await #expect(throws: ExportError.nothingRecorded) {
            try await MP4Exporter.export(
                core: core, display: UUID(),
                from: recording.start, to: recording.start.addingTimeInterval(60), to: url
            )
        }
        #expect(try Data(contentsOf: url) == Data("keep me".utf8))
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).allSatisfy { !$0.contains("partial") })
    }

    /// Long gaps are when recording stopped, and a clip shouldn't sit on them.
    @Test func longGapsAreCutShort() {
        #expect(MP4Exporter.onScreenTime(forGap: 2) == 2)
        #expect(MP4Exporter.onScreenTime(forGap: 60) == 60)
        #expect(MP4Exporter.onScreenTime(forGap: 3600) == MP4Exporter.heldGap)
    }

    /// A stretch that starts in a gap doesn't reach back to whatever was recorded hours ago.
    @Test func aStartInAGapBeginsAtTheNextFrame() async throws {
        let (core, recording, directory) = try await fixture(count: 3)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "clip.mp4")
        await #expect(throws: ExportError.nothingRecorded) {
            // Hours after the last frame, with nothing following it.
            try await MP4Exporter.export(
                core: core, display: recording.display,
                from: recording.start.addingTimeInterval(3 * 3600),
                to: recording.start.addingTimeInterval(4 * 3600),
                to: url
            )
        }
    }

    @Test func nothingRecordedInThatPeriodIsAnError() async throws {
        let (core, recording, directory) = try await fixture(count: 3)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "clip.mp4")
        await #expect(throws: ExportError.nothingRecorded) {
            try await MP4Exporter.export(
                core: core,
                display: UUID(),
                from: recording.start,
                to: recording.start.addingTimeInterval(60),
                to: url
            )
        }
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }
}
