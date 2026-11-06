import CoreAPI
import CoreGraphics
import Foundation

/// Converts between times and positions on the strip. Everything about selecting on the
/// strip works in this, so it can be tested without a window.
public struct StripGeometry: Equatable, Sendable {
    /// Where the playhead is on the axis, in the middle of the strip.
    public var centerPosition: Double
    public var pointsPerSecond: Double
    public var width: Double
    public var axis: StripAxis

    /// A strip with nothing squeezed, with a moment under the playhead.
    public init(center: Date, pointsPerSecond: Double, width: Double) {
        let axis = StripAxis()
        self.init(centerPosition: axis.position(of: center), pointsPerSecond: pointsPerSecond, width: width, axis: axis)
    }

    public init(centerPosition: Double, pointsPerSecond: Double, width: Double, axis: StripAxis) {
        self.centerPosition = centerPosition
        self.pointsPerSecond = pointsPerSecond
        self.width = width
        self.axis = axis
    }

    public func x(for time: Date) -> Double {
        width / 2 + (axis.position(of: time) - centerPosition) * pointsPerSecond
    }

    public func position(atX x: Double) -> Double {
        centerPosition + (x - width / 2) / pointsPerSecond
    }

    public func time(atX x: Double) -> Date {
        axis.time(at: position(atX: x))
    }
}

/// Picks out a stretch of time on the strip: a click takes a whole run, a drag draws any
/// stretch, and the ends of what's selected can be dragged to trim it.
public struct SliceEditor: Equatable, Sendable {
    /// How close to a run's edge a drag has to be to land on it, in points.
    public static let snapDistance = 8.0
    /// How close to an end of the selection counts as grabbing it, in points.
    public static let handleReach = 9.0
    /// Moving less than this between press and release is a click, in points.
    public static let dragThreshold = 3.0

    private enum Gesture: Equatable {
        case idle
        /// Pressed, and not moved far enough yet to say what this is.
        case pressed(x: Double)
        /// Drawing a new stretch from this anchor.
        case drawing(anchor: Date)
        case trimmingStart
        case trimmingEnd
    }

    public enum Outcome: Equatable, Sendable {
        /// Pressed and released without really moving. Says where.
        case clicked(Date)
        /// A drag finished, and `selection` holds the result.
        case selected
        case nothing
    }

    public private(set) var selection: DateInterval?
    private var gesture = Gesture.idle

    public init(selection: DateInterval? = nil) {
        self.selection = selection
    }

    public var isDragging: Bool {
        switch gesture {
        case .drawing, .trimmingStart, .trimmingEnd: true
        case .idle, .pressed: false
        }
    }

    public mutating func clear() {
        selection = nil
        gesture = .idle
    }

    public mutating func select(_ interval: DateInterval) {
        selection = interval
        gesture = .idle
    }

    /// Whether a position is over an end of the selection.
    public func isOverHandle(x: Double, geometry: StripGeometry) -> Bool {
        guard let selection else { return false }
        return abs(x - geometry.x(for: selection.start)) <= Self.handleReach
            || abs(x - geometry.x(for: selection.end)) <= Self.handleReach
    }

    public mutating func mouseDown(x: Double, geometry: StripGeometry) {
        if let selection {
            // The nearer end, when they're close enough together for both to be in reach.
            let toStart = abs(x - geometry.x(for: selection.start))
            let toEnd = abs(x - geometry.x(for: selection.end))
            if min(toStart, toEnd) <= Self.handleReach {
                gesture = toStart <= toEnd ? .trimmingStart : .trimmingEnd
                return
            }
        }
        gesture = .pressed(x: x)
    }

    public mutating func mouseDragged(
        x: Double,
        geometry: StripGeometry,
        runs: [TimelineRun],
        limits: ClosedRange<Date>
    ) {
        let time = Self.snapped(geometry.time(atX: x), geometry: geometry, runs: runs, limits: limits)
        switch gesture {
        case .idle:
            break
        case .pressed(let startX):
            guard abs(x - startX) >= Self.dragThreshold else { return }
            let anchor = Self.snapped(geometry.time(atX: startX), geometry: geometry, runs: runs, limits: limits)
            gesture = .drawing(anchor: anchor)
            selection = Self.interval(anchor, time)
        case .drawing(let anchor):
            selection = Self.interval(anchor, time)
        case .trimmingStart:
            guard let selection else { return }
            // Dragging one end past the other turns it into the other end.
            if time > selection.end {
                gesture = .trimmingEnd
                self.selection = Self.interval(selection.end, time)
            } else {
                self.selection = Self.interval(time, selection.end)
            }
        case .trimmingEnd:
            guard let selection else { return }
            if time < selection.start {
                gesture = .trimmingStart
                self.selection = Self.interval(time, selection.start)
            } else {
                self.selection = Self.interval(selection.start, time)
            }
        }
    }

    public mutating func mouseUp(x: Double, geometry: StripGeometry) -> Outcome {
        defer { gesture = .idle }
        switch gesture {
        case .idle:
            return .nothing
        case .pressed:
            return .clicked(geometry.time(atX: x))
        case .drawing, .trimmingStart, .trimmingEnd:
            return .selected
        }
    }

    private static func interval(_ a: Date, _ b: Date) -> DateInterval {
        DateInterval(start: min(a, b), end: max(a, b))
    }

    /// Lands on a run's edge when close to one, because that's nearly always what's meant:
    /// a stretch that ends where an app ends takes nothing from the next app.
    static func snapped(
        _ time: Date,
        geometry: StripGeometry,
        runs: [TimelineRun],
        limits: ClosedRange<Date>
    ) -> Date {
        let x = geometry.x(for: time)
        var best = time
        var bestDistance = snapDistance
        for run in runs {
            for edge in [run.start, run.end] {
                let distance = abs(geometry.x(for: edge) - x)
                if distance < bestDistance {
                    best = edge
                    bestDistance = distance
                }
            }
        }
        return min(max(best, limits.lowerBound), limits.upperBound)
    }

    /// The run at a moment.
    public static func run(at time: Date, in runs: [TimelineRun]) -> TimelineRun? {
        runs.first { $0.start <= time && time <= $0.end }
    }
}

/// Words for a stretch of time, in the ways the interface needs them.
public enum SliceDescription {
    /// "14:02 – 14:31", or with dates when it spans more than a day.
    public static func range(_ interval: DateInterval, calendar: Calendar = .current) -> String {
        let sameDay = calendar.isDate(interval.start, inSameDayAs: interval.end)
        let isToday = calendar.isDateInToday(interval.start)
        // A short stretch can start and end in the same minute, so it needs the seconds.
        let isShort = interval.duration < 600
        let time = isShort
            ? Date.FormatStyle.dateTime.hour().minute().second()
            : Date.FormatStyle.dateTime.hour().minute()
        if sameDay && isToday {
            return "\(interval.start.formatted(time)) – \(interval.end.formatted(time))"
        }
        let day = isShort
            ? Date.FormatStyle.dateTime.month(.abbreviated).day().hour().minute().second()
            : Date.FormatStyle.dateTime.month(.abbreviated).day().hour().minute()
        if sameDay {
            return "\(interval.start.formatted(day)) – \(interval.end.formatted(time))"
        }
        return "\(interval.start.formatted(day)) – \(interval.end.formatted(day))"
    }

    /// "29 minutes", "2 hours, 5 minutes", "1 minute, 14 seconds", or "40 seconds". Seconds
    /// stay in while they matter, so a stretch isn't described as shorter than it looks.
    public static func duration(_ seconds: TimeInterval) -> String {
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .full
        formatter.maximumUnitCount = 2
        formatter.allowedUnits = seconds < 60 ? [.second]
            : seconds < 600 ? [.minute, .second]
            : [.day, .hour, .minute]
        return formatter.string(from: max(seconds, 1)) ?? ""
    }

    /// As short as it can be, for the strip: "10h", "3d", "25m".
    public static func shortDuration(_ seconds: TimeInterval) -> String {
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .abbreviated
        formatter.maximumUnitCount = 1
        formatter.allowedUnits = [.day, .hour, .minute, .second]
        return formatter.string(from: max(seconds, 1)) ?? ""
    }

    /// What deleting a stretch will remove, in full, for asking whether to go ahead.
    public static func deletionDetails(_ interval: DateInterval, summary: SliceSummary) -> String {
        var parts: [String] = []
        parts.append(String(localized: "From \(range(interval))."))
        let size = summary.bytes.formatted(.byteCount(style: .file))
        if summary.frames == 0 {
            parts.append(String(localized: "Nothing was recorded on screen in this stretch."))
        } else {
            parts.append(String(localized: "This removes \(size) of recordings, and all the text in them."))
        }
        if summary.transcriptLines > 0 {
            parts.append(String(localized: "What was said goes too."))
        }
        if summary.starred > 0 {
            parts.append(String(localized: "That includes \(summary.starred) starred moments."))
        }
        if summary.dependentFrames > 0, let until = summary.dependentUntil {
            let extra = duration(until.timeIntervalSince(interval.end))
            parts.append(String(localized: "The \(extra) just after it goes as well, because those frames can't be shown without it."))
        }
        return parts.joined(separator: " ")
    }
}
