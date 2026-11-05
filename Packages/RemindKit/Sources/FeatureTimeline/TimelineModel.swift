import CoreAPI
import DesignSystem
import Foundation
import FrameEngine
import Observation

/// What the timeline's controls show.
///
/// Scrubbing updates the playhead every frame, so the playhead's position isn't kept
/// here: nothing in SwiftUI re-renders on each tick. The label only changes when its
/// text does.
@MainActor
@Observable
public final class TimelineModel {
    /// The playhead's description, such as "23 seconds ago".
    public private(set) var timeLabel = ""
    public var isJumpToDateOpen = false
    public private(set) var currentContext: FrameContext?
    public private(set) var isAtNow = true

    /// Replaces the clock, so previews and tests can freeze time.
    public var now: () -> Date = Date.init

    public init() {}

    /// Updates the label for a playhead position, if the text would change.
    public func playheadMoved(to time: Date) {
        let text = TimeLabel.text(for: time, now: now())
        if text != timeLabel {
            timeLabel = text
        }
        let atNow = now().timeIntervalSince(time) < 5
        if atNow != isAtNow {
            isAtNow = atNow
        }
    }

    public func showContext(_ context: FrameContext?) {
        if context != currentContext {
            currentContext = context
        }
    }
}
