import Foundation

/// One scroll event, reduced to what matters. Keeping this apart from `NSEvent` means
/// the mapping from fingers to time can be tested with no window.
public struct ScrollInput: Equatable, Sendable {
    public var deltaX: Double
    public var deltaY: Double
    /// Trackpads report exact movement. Mouse wheels report coarse notches.
    public var hasPreciseDeltas: Bool
    /// Whether this comes from momentum after the fingers lifted.
    public var isMomentum: Bool
    /// Whether the fast-scroll modifier is held.
    public var isFast: Bool
    public var timestamp: TimeInterval

    public init(
        deltaX: Double,
        deltaY: Double,
        hasPreciseDeltas: Bool = true,
        isMomentum: Bool = false,
        isFast: Bool = false,
        timestamp: TimeInterval = 0
    ) {
        self.deltaX = deltaX
        self.deltaY = deltaY
        self.hasPreciseDeltas = hasPreciseDeltas
        self.isMomentum = isMomentum
        self.isFast = isFast
        self.timestamp = timestamp
    }
}

/// Turns scrolling into movement through time.
///
/// Scrolling moves the strip under a fixed playhead, like dragging it with your
/// fingers: moving content to the right or down reveals earlier time. macOS has already
/// applied the natural scrolling setting to these deltas, so this follows it.
public struct ScrollInterpreter: Sendable {
    /// How many points a mouse wheel notch moves. Wheels report small line counts.
    private static let pointsPerWheelLine = 24.0
    private static let fastMultiplier = 8.0

    /// How much time one point of scrolling covers, which sets the zoom.
    public var pointsPerSecond: Double

    private var lastTimestamp: TimeInterval?
    /// Seconds of timeline per second of real time, smoothed. Decides the decode mode.
    public private(set) var velocity = 0.0

    public init(pointsPerSecond: Double) {
        self.pointsPerSecond = pointsPerSecond
    }

    /// How many seconds a scroll event moves the playhead. Negative goes back in time.
    public mutating func seconds(for input: ScrollInput) -> Double {
        // Use only the stronger axis, so a slightly diagonal swipe doesn't fight itself.
        let raw = abs(input.deltaX) > abs(input.deltaY) ? input.deltaX : input.deltaY
        var points = raw
        if !input.hasPreciseDeltas {
            points *= Self.pointsPerWheelLine
        }
        if input.isFast {
            points *= Self.fastMultiplier
        }
        let seconds = -points / pointsPerSecond

        if let last = lastTimestamp, input.timestamp > last {
            let instant = seconds / (input.timestamp - last)
            velocity = velocity * 0.7 + instant * 0.3
        }
        lastTimestamp = input.timestamp
        return seconds
    }

    /// Clears the velocity when scrolling stops.
    public mutating func reset() {
        lastTimestamp = nil
        velocity = 0
    }
}

/// Zoom levels for the strip, from a day on screen down to seconds.
public enum TimelineZoom {
    public static let minimumPointsPerSecond = 0.02
    public static let maximumPointsPerSecond = 20.0
    /// About 2 points per 2-second frame, which is close enough to scrub frame by frame
    /// with a trackpad.
    public static let defaultPointsPerSecond = 1.5

    /// Where a zoom level sits between widest and closest, from 0 to 1. Zoom feels even in
    /// steps of a multiple, so this is on a logarithmic scale.
    public static func fraction(for pointsPerSecond: Double) -> Double {
        let low = log(minimumPointsPerSecond)
        let high = log(maximumPointsPerSecond)
        return min(max((log(pointsPerSecond) - low) / (high - low), 0), 1)
    }

    public static func pointsPerSecond(forFraction fraction: Double) -> Double {
        let low = log(minimumPointsPerSecond)
        let high = log(maximumPointsPerSecond)
        return exp(low + min(max(fraction, 0), 1) * (high - low))
    }

    /// A zoom level after a pinch of `magnification`, keeping within limits.
    public static func applying(magnification: Double, to pointsPerSecond: Double) -> Double {
        min(max(pointsPerSecond * (1 + magnification), minimumPointsPerSecond), maximumPointsPerSecond)
    }
}
