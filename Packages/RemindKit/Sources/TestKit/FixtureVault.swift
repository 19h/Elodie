import CoreAPI
import Foundation
import Ingest

public enum FixtureError: Error {
    case frameRefused(index: Int, outcome: AppendOutcome)
    case notIndexed(indexed: UInt64, expected: Int)
}

/// Records synthetic frames into a vault, for tests and benchmarks.
public enum FixtureVault {
    public struct Recording: @unchecked Sendable {
        public let display: UUID
        public let start: Date
        public let spacing: TimeInterval
        /// Each frame's text, indexed by the frame number in its barcode.
        public let words: [Set<String>]
        public let barcodeY: Int
        public var count: Int { words.count }

        public func time(of index: Int) -> Date {
            start.addingTimeInterval(Double(index) * spacing)
        }
    }

    /// Records `count` frames, spaced as real capture would be. Waits until they're
    /// committed before returning.
    public static func record(
        into core: any RemindCore,
        width: Int,
        height: Int,
        count: Int,
        keyframeInterval: Int = 30,
        display: UUID = UUID(),
        start: Date = Date(timeIntervalSince1970: 1_800_000_000),
        spacing: TimeInterval = 2,
        appForScene: @Sendable (String) -> String = { "com.example.\($0)" }
    ) async throws -> Recording {
        let screen = SyntheticScreen(width: width, height: height)
        let encoder = try HEVCEncoder(settings: EncoderSettings(
            width: width, height: height, keyframeInterval: keyframeInterval, rate: .quality(0.75)
        ))
        final class Box: @unchecked Sendable {
            let lock = NSLock()
            var frames: [EncodedFrame] = []
        }
        let box = Box()
        var words: [Set<String>] = []
        var appended = 0
        for index in 0..<count {
            let frame = screen.nextFrame()
            words.append(frame.words)
            encoder.encode(frame.pixelBuffer) { result in
                if case .success(let encoded) = result {
                    box.lock.withLock { box.frames.append(encoded) }
                }
            }
            try encoder.finish()
            let encoded = box.lock.withLock { box.frames[index] }
            let sample = EncodedSample(
                displayID: display,
                width: width,
                height: height,
                parameterSets: encoded.parameterSets,
                capturedAt: start.addingTimeInterval(Double(index) * spacing),
                monotonicNanoseconds: UInt64(index),
                isKeyframe: encoded.isKeyframe,
                context: FrameContext(bundleID: appForScene(frame.scene), window: "Fixture \(frame.scene)"),
                data: encoded.data
            )
            // Real capture is far slower than writing, but fixtures aren't, and a busy
            // disk can fill the queue. Wait before appending: dropping a P-frame would
            // make the engine refuse everything until the next keyframe, and the
            // recording would silently have holes.
            while UInt64(appended) >= core.stats().loggedFrames + 4 {
                try await Task.sleep(for: .milliseconds(2))
            }
            let outcome = try core.append(sample)
            guard outcome == .accepted else {
                throw FixtureError.frameRefused(index: index, outcome: outcome)
            }
            appended += 1
        }
        try core.sealAll()
        // Commits come in batches up to 5 seconds apart, and a busy machine takes longer.
        // A test on half a recording would fail in confusing ways, so this has to finish.
        let deadline = Date().addingTimeInterval(60)
        while core.stats().indexedFrames < UInt64(appended) {
            guard Date() < deadline else {
                throw FixtureError.notIndexed(indexed: core.stats().indexedFrames, expected: appended)
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        return Recording(display: display, start: start, spacing: spacing, words: words, barcodeY: screen.barcodeY)
    }
}
