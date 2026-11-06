/// Decides who gets a scroll event on its way to other apps.
///
/// ⌘⇧ and scrolling up moves back through time, as one motion: the swipe that opens the
/// timeline carries straight on moving through it. That takes care, because macOS keeps
/// sending a swipe to the app it started over, even after the timeline has covered that
/// app, and it carries on through momentum after the fingers lift. So once a swipe is
/// taken over it stays taken over until it finishes, even if the keys are let go.
///
/// Nothing else is touched: other scrolling passes straight through, and that includes ⌘⇧
/// and scrolling down when the timeline is closed, since there's no future to scroll to.
public struct ScrollGestureRouter: Sendable {
    public enum Decision: Equatable, Sendable {
        case passThrough
        case takeOver
    }

    /// `CGScrollPhase` values, which describe fingers on a trackpad.
    public enum Phase: Int64, Sendable {
        case none = 0
        case began = 1
        case changed = 2
        case ended = 4
        case cancelled = 8
        case mayBegin = 128
    }

    /// `CGMomentumScrollPhase` values, which describe the glide after the fingers lift.
    public enum Momentum: Int64, Sendable {
        case none = 0
        case began = 1
        case continuing = 2
        case ended = 3
    }

    /// In the middle of a swipe that's been taken over.
    private var latched = false

    public init() {}

    public mutating func route(
        modifiersHeld: Bool,
        overlayOpen: Bool,
        deltaY: Double,
        phase: Phase,
        momentum: Momentum
    ) -> Decision {
        let isFromWheel = phase == .none && momentum == .none

        if latched {
            // A new swipe, or a mouse wheel, without the keys is something else entirely.
            if !modifiersHeld, phase == .began || phase == .mayBegin || isFromWheel {
                latched = false
                return .passThrough
            }
            if momentum == .ended {
                latched = false
            }
            return .takeOver
        }

        guard modifiersHeld, overlayOpen || deltaY > 0 else { return .passThrough }
        // Wheels have no phases, so there's no swipe to follow to its end.
        latched = !isFromWheel && momentum != .ended
        return .takeOver
    }
}
