import Capture
import CoreAPI
import CoreFake
import CoreLive
import CoreVideo
import FrameEngine
import Foundation
@testable import Ingest
import TestKit
import Testing

/// From pixels to a search result, using the real encoder, vault, OCR, and index.
@Suite struct PixelsToSearch {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    private func makeCore() throws -> (LiveCore, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "elodie-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return (try LiveCore(vaultDirectory: directory, masterKey: Data(repeating: 3, count: 32)), directory)
    }

    /// Records synthetic frames and returns them.
    private func record(
        _ core: LiveCore,
        display: UUID,
        screen: SyntheticScreen,
        count: Int
    ) async throws -> [SyntheticScreen.Frame] {
        let encoder = try HEVCEncoder(settings: EncoderSettings(
            width: screen.width, height: screen.height, keyframeInterval: 10, rate: .quality(0.75)
        ))
        final class Holder: @unchecked Sendable {
            let lock = NSLock()
            var frames: [EncodedFrame] = []
        }
        let holder = Holder()
        var sources: [SyntheticScreen.Frame] = []
        for index in 0..<count {
            let frame = screen.nextFrame()
            sources.append(frame)
            encoder.encode(frame.pixelBuffer) { result in
                if case .success(let encoded) = result {
                    holder.lock.withLock { holder.frames.append(encoded) }
                }
            }
            try encoder.finish()
            let encoded = holder.lock.withLock { holder.frames[index] }
            let outcome = try core.append(EncodedSample(
                displayID: display,
                width: screen.width,
                height: screen.height,
                parameterSets: encoded.parameterSets,
                capturedAt: start.addingTimeInterval(Double(index) * 2),
                monotonicNanoseconds: UInt64(index),
                isKeyframe: encoded.isKeyframe,
                context: FrameContext(bundleID: "com.example.\(frame.scene)", window: frame.scene),
                data: encoded.data
            ))
            #expect(outcome == .accepted)
            // Wait for it to be written, so a busy disk can't fill the queue.
            while core.stats().loggedFrames <= UInt64(index) {
                try await Task.sleep(for: .milliseconds(2))
            }
        }
        try core.sealAll()
        // Give the writer's batch time to commit.
        try await Task.sleep(for: .milliseconds(1200))
        return sources
    }

    @Test func wordsOnScreenCanBeFoundAndLeadToTheRightFrame() async throws {
        let (core, directory) = try makeCore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let display = UUID()
        let screen = SyntheticScreen(width: 1512, height: 982)
        let sources = try await record(core, display: display, screen: screen, count: 12)

        // Run OCR to completion.
        let worker = OCRWorker(core: core)
        var reader = GroupReader(core: core)
        while try await worker.processBatch(&reader) {}
        #expect(worker.framesProcessed == 12)
        // Nothing should still be waiting.
        #expect(try core.nextOCRBatch(max: 8, now: start, includeDeferred: true).isEmpty)

        // Search for words known to be drawn, and check each result's frame really
        // shows the word, by reading the frame number burned into the picture.
        var checked = 0
        var found = 0
        for source in sources.prefix(6) {
            // Words of 6 or more letters are far less likely to appear by chance.
            for word in source.words.filter({ $0.count >= 6 }).sorted().prefix(4) {
                checked += 1
                let facets = SearchFacets()
                guard let session = try core.search(word + " ", facets: facets, order: .newest) else { continue }
                let page = try session.nextPage()
                guard let hit = page.hits.first else { continue }
                found += 1

                let group = try core.readGroup(containing: hit.frameID)
                let decoder = try HEVCDecoder(parameterSets: group.parameterSets, width: group.width, height: group.height)
                var image: CVPixelBuffer?
                for sample in group.samples[...group.target] {
                    image = try decoder.decode(sample.data)
                }
                let decoded = try #require(image)
                let number = try #require(FrameBarcode.read(from: decoded, originY: screen.barcodeY))
                #expect(sources[number].words.contains(word), "frame \(number) doesn't show \(word)")
                #expect(!hit.rects.isEmpty)
            }
        }
        #expect(checked >= 20)
        // Vision reads about 98% of words, so nearly everything should be findable.
        #expect(Double(found) / Double(checked) > 0.9, "only \(found) of \(checked) words were found")
    }

    /// A word's highlight has to land on the word. This draws one known word at a
    /// known place and checks the rectangle against it.
    @Test func recognizedTextHasATopLeftOriginAndTheRightPlace() async throws {
        let frame = TestFrames.withText("ZEBRAFISH", width: 1200, height: 800, at: CGPoint(x: 900, y: 80))
        let lines = try await OCRWorker.recognize(frame)
        let line = try #require(lines.first { $0.text.contains("ZEBRAFISH") })
        // Near the top right. If the origin were flipped, y would be near the bottom.
        #expect(line.rect.minY < 0.2, "y = \(line.rect.minY)")
        #expect(line.rect.minX > 0.6, "x = \(line.rect.minX)")
        #expect(line.rect.maxX <= 1.01)
    }

    @Test func aFrameThatCannotBeReadIsGivenUpOnEventually() async throws {
        let (core, directory) = try makeCore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let display = UUID()
        _ = try await record(core, display: display, screen: SyntheticScreen(width: 640, height: 400), count: 1)

        // Fetching counts as an attempt, as it would if OCR crashed the app each time.
        for _ in 0..<3 {
            let jobs = try core.nextOCRBatch(max: 8, now: start, includeDeferred: false)
            #expect(jobs.count == 1)
        }
        #expect(try core.nextOCRBatch(max: 8, now: start, includeDeferred: true).isEmpty)
    }

    @Test func frameFallsBehindAndCatchesUp() async throws {
        let (core, directory) = try makeCore()
        defer { try? FileManager.default.removeItem(at: directory) }
        _ = try await record(core, display: UUID(), screen: SyntheticScreen(width: 640, height: 400), count: 5)
        // A fetch long after the frames were captured: OCR is far behind, and the
        // frames were 2 seconds apart, so all but the last are set aside.
        let later = start.addingTimeInterval(3600)
        let urgent = try core.nextOCRBatch(max: 8, now: later, includeDeferred: false)
        #expect(urgent.count == 1)
        // On an idle machine the rest come back.
        let rest = try core.nextOCRBatch(max: 8, now: later, includeDeferred: true)
        #expect(rest.count >= 4)
    }
}
