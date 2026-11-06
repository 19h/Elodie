import CoreVideo
import Foundation

/// A decoded frame.
public struct DecodedFrame: @unchecked Sendable {
    public let frameID: Int64
    public let capturedAt: Date
    public let buffer: CVPixelBuffer

    public init(frameID: Int64, capturedAt: Date, buffer: CVPixelBuffer) {
        self.frameID = frameID
        self.capturedAt = capturedAt
        self.buffer = buffer
    }

    /// How much memory this holds.
    var byteCount: Int {
        // 4:2:0 is 1.5 bytes per pixel, whatever the row padding.
        CVPixelBufferGetWidth(buffer) * CVPixelBufferGetHeight(buffer) * 3 / 2
    }
}

/// Decoded frames near the playhead.
///
/// Going backward through P-frames means restarting from a keyframe, so a whole group
/// gets decoded for one frame, and keeping the rest makes the next step instant. The
/// budget bounds memory, because a 5K frame is about 22 MB.
///
/// Not thread-safe, and owned by the scrub engine's queue.
final class FrameCache {
    private var entries: [Int64: DecodedFrame] = [:]
    private var bytes = 0
    private var pinned: Set<Int64> = []
    var budget: Int

    init(budget: Int) {
        self.budget = budget
    }

    var count: Int { entries.count }
    var byteCount: Int { bytes }

    func frame(_ id: Int64) -> DecodedFrame? {
        entries[id]
    }

    /// Frames that must stay, such as the one on screen.
    func pin(_ ids: Set<Int64>) {
        pinned = ids
    }

    /// Adds a frame, then evicts down to the budget, starting with whatever's
    /// farthest from `target`. Frames behind the direction of travel count as
    /// farther, because they're less likely to be wanted next.
    func insert(_ frame: DecodedFrame, target: Int64, direction: Int) {
        if let existing = entries[frame.frameID] {
            bytes -= existing.byteCount
        }
        entries[frame.frameID] = frame
        bytes += frame.byteCount
        evict(target: target, direction: direction)
    }

    func evict(target: Int64, direction: Int) {
        guard bytes > budget else { return }
        let ordered = entries.keys
            .filter { !pinned.contains($0) && $0 != target }
            .sorted { distance($0, target, direction) > distance($1, target, direction) }
        for id in ordered {
            guard bytes > budget else { return }
            if let removed = entries.removeValue(forKey: id) {
                bytes -= removed.byteCount
            }
        }
    }

    /// The closest frame to `target` that doesn't move away from where the view
    /// already is. That way the fallback picture never jumps the wrong way.
    func nearest(to target: Int64, notBehind shown: Int64?) -> DecodedFrame? {
        var best: DecodedFrame?
        var bestDistance = Int64.max
        for (id, frame) in entries {
            let gap = abs(id - target)
            if let shown, abs(shown - target) <= gap {
                continue
            }
            if gap < bestDistance {
                best = frame
                bestDistance = gap
            }
        }
        return best
    }

    private func distance(_ id: Int64, _ target: Int64, _ direction: Int) -> Double {
        let raw = Double(id - target)
        let behind = direction != 0 && (raw > 0) != (direction > 0)
        return abs(raw) * (behind ? 2 : 1)
    }
}
