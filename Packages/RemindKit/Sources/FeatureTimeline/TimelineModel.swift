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

    /// Hidden for an instant on opening, so the controls rise after the screen has stopped.
    public var isChromeVisible = false
    /// Whether the search panel is showing. Opening by scrolling leaves the frame clear,
    /// so it looks like the screen itself going back in time.
    public var isSearchVisible = true
    /// Nothing has been recorded on this display, or none of it is left.
    public var isEmpty = false

    /// The run under the pointer on the strip.
    public var hover: StripHover?
    /// The stretch picked out on the strip, and what it holds.
    public private(set) var slice: DateInterval?
    public private(set) var sliceSummary: SliceSummary?
    /// Where the picture is on screen, with the origin at the top left. It only fills the
    /// screen when it's from a display of the same shape.
    public var pictureRect: CGRect?
    /// Asking whether to forget the last 5 minutes.
    public var isConfirmingForget = false
    /// The displays with recordings, when there's more than one to choose from.
    public var recordedDisplays: [DisplayChoice] = []
    public var shownDisplay: UUID?
    public var isConfirmingDelete = false
    public var isDeleting = false

    /// Where the zoom control is, from 0 for the widest view to 1 for the closest.
    public var zoomFraction = 0.5
    public var isZoomOpen = false

    /// Whether the moment on screen is starred.
    public var isStarred = false

    /// A short note that something happened, which goes away by itself.
    public private(set) var toast: String?
    private var toastGeneration = 0

    public func showToast(_ text: String) {
        toastGeneration += 1
        let generation = toastGeneration
        toast = text
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(2.5))
            if self?.toastGeneration == generation {
                self?.toast = nil
            }
        }
    }

    func setSlice(_ slice: DateInterval?) {
        guard slice != self.slice else { return }
        self.slice = slice
        sliceSummary = nil
        isConfirmingDelete = false
    }

    func setSliceSummary(_ summary: SliceSummary?) {
        sliceSummary = summary
    }

    /// Clears everything from the last time this was open.
    func reset() {
        pictureRect = nil
        isConfirmingForget = false
        isJumpToDateOpen = false
        isChromeVisible = false
        hover = nil
        slice = nil
        sliceSummary = nil
        recordedDisplays = []
        isConfirmingDelete = false
        isDeleting = false
        isZoomOpen = false
        toast = nil
        isEmpty = false
        isStarred = false
    }
}

/// A display that can be looked back through.
public struct DisplayChoice: Identifiable, Equatable, Sendable {
    public var id: UUID
    public var name: String

    public init(id: UUID, name: String) {
        self.id = id
        self.name = name
    }
}

/// What's under the pointer on the strip.
public struct StripHover: Equatable, Sendable {
    /// Where the pointer is along the strip, in points.
    public var x: Double
    public var start: Date
    public var end: Date
    public var bundleID: String?
    public var window: String?
    public var url: String?

    public init(x: Double, start: Date, end: Date, bundleID: String?, window: String? = nil, url: String? = nil) {
        self.x = x
        self.start = start
        self.end = end
        self.bundleID = bundleID
        self.window = window
        self.url = url
    }
}
