import CoreAPI
import CoreVideo
import Foundation
import FrameEngine
import Ingest
import TestKit

/// Measurements that need no permissions, recorded in docs/spikes.md.
@main
struct Spike {
    static func main() async throws {
        let arguments = CommandLine.arguments.dropFirst()
        switch arguments.first {
        case "holdback":
            try holdback()
        case "storage":
            try await storage(frames: arguments.dropFirst().first.flatMap(Int.init) ?? 450)
        default:
            print("usage: remind-spike holdback | storage [frames]")
        }
    }
}

final class Output: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var frames: [EncodedFrame] = []
    private(set) var failures = 0

    func add(_ result: Result<EncodedFrame, any Error>) {
        lock.withLock {
            switch result {
            case .success(let frame): frames.append(frame)
            case .failure: failures += 1
            }
        }
    }

    var count: Int { lock.withLock { frames.count } }
    var all: [EncodedFrame] { lock.withLock { frames } }
}

func milliseconds(_ duration: Duration) -> Double {
    let (seconds, attoseconds) = duration.components
    return Double(seconds) * 1000 + Double(attoseconds) / 1e15
}

func percentile(_ values: [Double], _ percent: Int) -> Double {
    guard !values.isEmpty else { return 0 }
    let sorted = values.sorted()
    return sorted[(sorted.count - 1) * percent / 100]
}

/// Does the encoder hold frames back, and what does forcing them out cost?
func holdback() throws {
    let width = 3024, height = 1964, count = 90
    print("Encoder hold-back at \(width)×\(height), \(count) frames, keyframe every 30\n")

    for (name, flush) in [("no flush", false), ("flush after each frame", true)] {
        let screen = SyntheticScreen(width: width, height: height)
        let encoder = try HEVCEncoder(settings: EncoderSettings(
            width: width, height: height, keyframeInterval: 30, rate: .quality(0.65)
        ))
        let output = Output()
        var maxBehind = 0
        var encodeTimes: [Double] = []
        let clock = ContinuousClock()

        for index in 0..<count {
            let frame = screen.nextFrame()
            let started = clock.now
            encoder.encode(frame.pixelBuffer) { output.add($0) }
            if flush {
                try encoder.finish()
            } else {
                // Real frames are seconds apart, so give it far longer than a
                // frame takes to encode.
                Thread.sleep(forTimeInterval: 0.05)
            }
            encodeTimes.append(milliseconds(clock.now - started))
            maxBehind = max(maxBehind, index + 1 - output.count)
        }
        try encoder.finish()
        let frames = output.all
        let keyframes = frames.filter(\.isKeyframe).count
        let bytes = frames.reduce(0) { $0 + $1.data.count }
        print("\(name):")
        print("  most frames held inside the encoder  \(maxBehind)")
        print("  keyframes                            \(keyframes) of \(frames.count)")
        print("  average frame                        \(bytes / max(frames.count, 1)) bytes")
        if flush {
            print("  encode and flush                     p50 \(String(format: "%.1f", percentile(encodeTimes, 50))) ms, p95 \(String(format: "%.1f", percentile(encodeTimes, 95))) ms")
        }
        print()
    }
}

struct GridPoint: Sendable {
    var rate: EncoderRate
    var keyframeInterval: Int
}

/// Spike 3: the storage and seek grid.
func storage(frames count: Int) async throws {
    let width = 3024, height = 1964
    let grid: [GridPoint] = [
        GridPoint(rate: .bitsPerPixel(0.06375), keyframeInterval: 30),
        GridPoint(rate: .bitsPerPixel(0.06375), keyframeInterval: 60),
        GridPoint(rate: .bitsPerPixel(0.06375), keyframeInterval: 150),
        GridPoint(rate: .quality(0.4), keyframeInterval: 30),
        GridPoint(rate: .quality(0.5), keyframeInterval: 30),
        GridPoint(rate: .quality(0.65), keyframeInterval: 30),
        GridPoint(rate: .quality(0.8), keyframeInterval: 30),
        GridPoint(rate: .quality(0.5), keyframeInterval: 60),
        GridPoint(rate: .quality(0.65), keyframeInterval: 60),
        GridPoint(rate: .quality(0.65), keyframeInterval: 150),
    ]
    print("Storage grid at \(width)×\(height), \(count) synthetic frames each.")
    print("Per-day figures assume all 14,400 ticks in 8 hours are stored, which is the worst case.")
    print("OCR recall compares decoded frames with what was drawn; \"src\" is OCR on the source frames.\n")

    print("rate                     GOP   avg KB  key KB  GB/8h  seek p50  seek p95  PSNR dB  OCR%  src%")
    for point in grid {
        let result = try await measure(point, width: width, height: height, count: count)
        let label = point.rate.description.padding(toLength: 24, withPad: " ", startingAt: 0)
        print(
            label,
            String(format: "%3d  %7.1f %7.1f %6.2f %7.1f %9.1f %8.1f %6.2f %5.2f",
                   point.keyframeInterval,
                   result.averageBytes / 1000,
                   result.averageKeyframeBytes / 1000,
                   result.averageBytes * 14_400 / 1e9,
                   result.seekP50,
                   result.seekP95,
                   result.psnr,
                   result.ocrRecall * 100,
                   result.sourceRecall * 100)
        )
    }
}

struct Measurement {
    var averageBytes: Double
    var averageKeyframeBytes: Double
    var seekP50: Double
    var seekP95: Double
    var psnr: Double
    var ocrRecall: Double
    var sourceRecall: Double
}

func measure(_ point: GridPoint, width: Int, height: Int, count: Int) async throws -> Measurement {
    let screen = SyntheticScreen(width: width, height: height)
    let encoder = try HEVCEncoder(settings: EncoderSettings(
        width: width, height: height, keyframeInterval: point.keyframeInterval, rate: point.rate
    ))
    let output = Output()

    // A few frames to check quality on, spread across the run.
    let sampleEvery = max(count / 12, 1)
    var samples: [(index: Int, source: CVPixelBuffer, words: Set<String>)] = []

    for index in 0..<count {
        let frame = screen.nextFrame()
        if index % sampleEvery == sampleEvery / 2 {
            samples.append((index, frame.pixelBuffer, frame.words))
        }
        encoder.encode(frame.pixelBuffer) { output.add($0) }
        try encoder.finish()
    }
    let frames = output.all
    precondition(output.failures == 0, "encoding failed")

    let keyframeIndices = frames.indices.filter { frames[$0].isKeyframe }
    let keyframeBytes = keyframeIndices.reduce(0) { $0 + frames[$1].data.count }
    let totalBytes = frames.reduce(0) { $0 + $1.data.count }

    // Seek the slow way, as if nothing were cached: decode from the keyframe.
    var seekTimes: [Double] = []
    let clock = ContinuousClock()
    var generator = SystemRandomNumberGenerator()
    for _ in 0..<40 {
        let target = Int.random(in: 0..<frames.count, using: &generator)
        let start = keyframeIndices.last(where: { $0 <= target }) ?? 0
        let started = clock.now
        let decoder = try HEVCDecoder(parameterSets: frames[start].parameterSets, width: width, height: height)
        for index in start...target {
            _ = try decoder.decode(frames[index].data)
        }
        seekTimes.append(milliseconds(clock.now - started))
    }

    var psnrTotal = 0.0
    var decodedHits = 0, sourceHits = 0, truth = 0
    for sample in samples {
        let start = keyframeIndices.last(where: { $0 <= sample.index }) ?? 0
        let decoder = try HEVCDecoder(parameterSets: frames[start].parameterSets, width: width, height: height)
        var image: CVPixelBuffer?
        for index in start...sample.index {
            image = try decoder.decode(frames[index].data)
        }
        guard let image else { continue }
        psnrTotal += ImageQuality.lumaPSNR(sample.source, image)

        let decodedText = try await TextRecognizer.words(in: image)
        let sourceText = try await TextRecognizer.words(in: sample.source)
        truth += sample.words.count
        decodedHits += sample.words.intersection(decodedText).count
        sourceHits += sample.words.intersection(sourceText).count
    }

    return Measurement(
        averageBytes: Double(totalBytes) / Double(frames.count),
        averageKeyframeBytes: Double(keyframeBytes) / Double(max(keyframeIndices.count, 1)),
        seekP50: percentile(seekTimes, 50),
        seekP95: percentile(seekTimes, 95),
        psnr: psnrTotal / Double(max(samples.count, 1)),
        ocrRecall: Double(decodedHits) / Double(max(truth, 1)),
        sourceRecall: Double(sourceHits) / Double(max(truth, 1))
    )
}
