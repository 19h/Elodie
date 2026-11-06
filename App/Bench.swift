#if DEBUG
import AppKit
import CoreAPI
import CoreLive
import Foundation
import FrameEngine
import TestKit

/// Measures how fast scrubbing is against the plan's budgets, on a real encoded fixture
/// at this Mac's display size. It uses no window and needs no permission, so it can run
/// at any time. This Mac is fast, so these numbers flatter what slower Macs will see.
enum Bench {
    private final class Timings: @unchecked Sendable {
        let lock = NSLock()
        var started = ContinuousClock.now
        var first: Duration?
        var exact: Duration?

        func reset() {
            lock.withLock {
                started = .now
                first = nil
                exact = nil
            }
        }

        func note(_ update: ScrubUpdate) {
            lock.withLock {
                let elapsed = ContinuousClock.now - started
                if first == nil { first = elapsed }
                if update.isExact, exact == nil { exact = elapsed }
            }
        }
    }

    private static func milliseconds(_ duration: Duration) -> Double {
        let (seconds, attoseconds) = duration.components
        return Double(seconds) * 1000 + Double(attoseconds) / 1e15
    }

    private static func percentile(_ values: [Double], _ fraction: Double) -> Double {
        guard !values.isEmpty else { return .nan }
        let sorted = values.sorted()
        return sorted[min(Int(Double(sorted.count) * fraction), sorted.count - 1)]
    }

    private static func line(_ name: String, _ values: [Double], budget: String) -> String {
        String(
            format: "%@: p50 %.1f ms, p95 %.1f ms, p99 %.1f ms (%d samples, budget %@)",
            name, percentile(values, 0.5), percentile(values, 0.95), percentile(values, 0.99), values.count, budget
        )
    }

    @MainActor
    static func run(to output: URL) async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "elodie-bench-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let core = try LiveCore(vaultDirectory: directory, masterKey: Data(repeating: 6, count: 32))
        let display = UUID()
        let count = 300
        let width = 3024
        let height = 1964
        let recording = try await FixtureVault.record(
            into: core,
            width: width,
            height: height,
            count: count,
            display: display,
            start: Date().addingTimeInterval(-Double(count) * 2)
        )

        let engine = ScrubEngine(core: core, display: display)
        let timings = Timings()
        engine.onUpdate = { timings.note($0) }

        func seek(_ index: Int, velocity: Double = 0) async -> (first: Double?, exact: Double?) {
            timings.reset()
            engine.seek(.init(time: recording.time(of: index), velocity: velocity))
            for _ in 0..<400 {
                let done = timings.lock.withLock { timings.exact != nil }
                if done { break }
                try? await Task.sleep(for: .milliseconds(1))
            }
            return timings.lock.withLock {
                (timings.first.map(milliseconds), timings.exact.map(milliseconds))
            }
        }

        var lines = ["\(width)×\(height), \(count) frames, keyframe every 30"]

        // Backward through uncached groups, which is the expensive direction.
        var firstChange: [Double] = []
        var exactFrame: [Double] = []
        var index = count - 1
        while index > 30 {
            engine.purge()
            engine.waitUntilIdle()
            let result = await seek(index)
            if let first = result.first { firstChange.append(first) }
            if let exact = result.exact { exactFrame.append(exact) }
            // Lets settling finish, so each sample starts from the same place.
            try await Task.sleep(for: .milliseconds(90))
            engine.waitUntilIdle()
            index -= 7
        }
        lines.append(line("backward miss, first change", firstChange, budget: "50 ms"))
        lines.append(line("backward miss, exact frame", exactFrame, budget: "p95 120 ms, p99 280 ms"))

        // Around a settled position, where neighbouring groups are cached.
        let center = count / 2
        _ = await seek(center)
        try await Task.sleep(for: .milliseconds(1500))
        engine.waitUntilIdle()
        var cached: [Double] = []
        for offset in stride(from: -14, through: 14, by: 1) where offset != 0 {
            if let exact = await seek(center + offset, velocity: 2).exact { cached.append(exact) }
        }
        lines.append(line("scrub, cached", cached, budget: "p95 25 ms"))

        // A fast flick, which should keep up by showing keyframes.
        var flick: [Double] = []
        for position in stride(from: count - 1, to: 0, by: -5) {
            timings.reset()
            engine.seek(.init(time: recording.time(of: position), velocity: -400))
            for _ in 0..<200 where timings.lock.withLock({ timings.first == nil }) {
                try await Task.sleep(for: .milliseconds(1))
            }
            if let first = timings.lock.withLock({ timings.first }) { flick.append(milliseconds(first)) }
        }
        lines.append(line("fast flick, per update", flick, budget: "keeps up with a 60 Hz display"))

        // Where a miss spends its time.
        let target = try core.lookup(display: display, at: recording.time(of: 30))!.id
        var reading: [Double] = []
        var sessions: [Double] = []
        var firstFrames: [Double] = []
        var perFrame: [Double] = []
        var bytes = 0
        for _ in 0..<12 {
            var mark = ContinuousClock.now
            let group = try core.readGroup(containing: target)
            reading.append(milliseconds(ContinuousClock.now - mark))
            bytes = group.samples.reduce(0) { $0 + $1.data.count }

            mark = ContinuousClock.now
            let decoder = try HEVCDecoder(parameterSets: group.parameterSets, width: group.width, height: group.height)
            sessions.append(milliseconds(ContinuousClock.now - mark))

            mark = ContinuousClock.now
            _ = try decoder.decode(group.samples[0].data)
            firstFrames.append(milliseconds(ContinuousClock.now - mark))

            mark = ContinuousClock.now
            for sample in group.samples.dropFirst() {
                _ = try decoder.decode(sample.data)
            }
            perFrame.append(milliseconds(ContinuousClock.now - mark) / Double(group.samples.count - 1))
        }
        lines.append(line("reading a group (\(bytes / 1024) KB)", reading, budget: "part of a miss"))
        lines.append(line("creating a decoder", sessions, budget: "part of a miss"))
        lines.append(line("decoding a keyframe", firstFrames, budget: "part of a miss"))
        lines.append(line("decoding each later frame", perFrame, budget: "plan assumed 8 ms"))

        try lines.joined(separator: "\n").write(to: output, atomically: true, encoding: .utf8)
    }
}
#endif
