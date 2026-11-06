import Foundation

/// The strip's axis: what was recorded at its true scale, with each stretch where nothing
/// was recorded squeezed down to a short break. Ten hours away takes no more scrolling to
/// cross than ten minutes.
///
/// A position is seconds along the axis, so the distance between two positions times the
/// zoom is the distance between them in points. A break keeps the same width at every zoom,
/// which means the axis depends on the zoom and is rebuilt when it changes.
public struct StripAxis: Equatable, Sendable {
    /// The most room a stretch with nothing recorded takes on the strip, in points. It's
    /// about enough for its label, so it reads as a break and not as a stretch of time.
    public static let breakWidth = 36.0
    /// Anything shorter is the normal rhythm of recording, and it stays to scale.
    public static let shortestBreak: TimeInterval = 30

    private struct Entry: Equatable, Sendable {
        var start: Double
        var end: Double
        /// Where the break starts on the axis.
        var position: Double
        /// How much time has been taken out of the axis by the end of this break.
        var removed: Double
    }

    private let entries: [Entry]
    /// How long each break is on the axis.
    private let length: Double

    /// An axis with nothing squeezed, where a position is just a time.
    public init() {
        entries = []
        length = 0
    }

    /// - Parameter gaps: Where nothing was recorded, oldest first.
    public init(gaps: [DateInterval], pointsPerSecond: Double) {
        let length = Self.breakWidth / pointsPerSecond
        var entries: [Entry] = []
        entries.reserveCapacity(gaps.count)
        var removed = 0.0
        for gap in gaps where gap.duration >= Self.shortestBreak && gap.duration > length {
            let start = gap.start.timeIntervalSinceReferenceDate
            let position = start - removed
            removed += gap.duration - length
            entries.append(Entry(start: start, end: gap.end.timeIntervalSinceReferenceDate, position: position, removed: removed))
        }
        self.entries = entries
        // With nothing squeezed, the zoom makes no difference, and nothing has to be redone.
        self.length = entries.isEmpty ? 0 : length
    }

    /// The gaps left between stretches of recording.
    public static func gaps(between periods: [DateInterval]) -> [DateInterval] {
        zip(periods, periods.dropFirst()).compactMap { earlier, later in
            later.start > earlier.end ? DateInterval(start: earlier.end, end: later.start) : nil
        }
    }

    /// Where a moment is on the axis. A moment inside a break goes in proportion to how far
    /// through it is, so things drawn there keep their order.
    public func position(of time: Date) -> Double {
        let seconds = time.timeIntervalSinceReferenceDate
        guard let index = lastIndex(atOrBefore: seconds, by: \.start) else { return seconds }
        let entry = entries[index]
        if seconds >= entry.end { return seconds - entry.removed }
        return entry.position + (seconds - entry.start) / (entry.end - entry.start) * length
    }

    /// The moment at a position. There's nothing to show inside a break, so anywhere in one
    /// is the nearer of the two moments either side of it.
    public func time(at position: Double) -> Date {
        guard let index = lastIndex(atOrBefore: position, by: \.position) else {
            return Date(timeIntervalSinceReferenceDate: position)
        }
        let entry = entries[index]
        if position >= entry.position + length {
            return Date(timeIntervalSinceReferenceDate: position + entry.removed)
        }
        return Date(timeIntervalSinceReferenceDate: position - entry.position < length / 2 ? entry.start : entry.end)
    }

    /// The stretch a position is in the break for, if it's in one.
    public func breakInterval(at position: Double) -> DateInterval? {
        guard let index = lastIndex(atOrBefore: position, by: \.position) else { return nil }
        let entry = entries[index]
        guard position < entry.position + length else { return nil }
        return Self.interval(of: entry)
    }

    /// The breaks that overlap a period, oldest first.
    public func breaks(in range: ClosedRange<Date>) -> [DateInterval] {
        let lower = range.lowerBound.timeIntervalSinceReferenceDate
        let upper = range.upperBound.timeIntervalSinceReferenceDate
        // Breaks don't overlap, so ends are in order too.
        let first = lastIndex(atOrBefore: lower, by: \.end).map { $0 + 1 } ?? 0
        return entries[first...].prefix { $0.start <= upper }.map(Self.interval(of:))
    }

    /// How much of a stretch has anything recorded in it.
    public static func recordedTime(in interval: DateInterval, gaps: [DateInterval]) -> TimeInterval {
        let missing = gaps.reduce(0.0) { total, gap in
            total + max(min(gap.end, interval.end).timeIntervalSince(max(gap.start, interval.start)), 0)
        }
        return max(interval.duration - missing, 0)
    }

    /// The zoom that makes a stretch take up a given width, breaks and all.
    public static func pointsPerSecond(toFit interval: DateInterval, gaps: [DateInterval], width: Double) -> Double {
        let squeezed = gaps.filter {
            $0.duration >= shortestBreak && $0.start >= interval.start && $0.end <= interval.end
        }
        let room = width - Double(squeezed.count) * breakWidth
        // With too many breaks to leave room, the whole stretch to scale is the closest fit.
        guard room >= width / 4 else { return width / max(interval.duration, 1) }
        return room / max(recordedTime(in: interval, gaps: squeezed), 1)
    }

    private static func interval(of entry: Entry) -> DateInterval {
        DateInterval(
            start: Date(timeIntervalSinceReferenceDate: entry.start),
            end: Date(timeIntervalSinceReferenceDate: entry.end)
        )
    }

    /// The last break whose value is at or before `value`, by binary search. There can be
    /// thousands of breaks, and this runs for every scroll event.
    private func lastIndex(atOrBefore value: Double, by key: (Entry) -> Double) -> Int? {
        var low = 0
        var high = entries.count
        while low < high {
            let middle = (low + high) / 2
            if key(entries[middle]) <= value {
                low = middle + 1
            } else {
                high = middle
            }
        }
        return low == 0 ? nil : low - 1
    }
}
