import AppKit
import Capture
import CoreAPI
import CoreGraphics
import CoreVideo
import Foundation

/// Why recording isn't running.
public enum RecordingState: Sendable, Equatable {
    case stopped
    case recording(displayID: CGDirectDisplayID)
    case interrupted(StreamStop)
}

/// Runs capture for the display the pointer is on.
///
/// It decides what's safe to keep, by asking which windows must be hidden and
/// whether the filter in effect covers them. See `ExclusionGate`.
public final class RecordingController: @unchecked Sendable {
    private let core: any RemindCore
    private let settings: PipelineSettings
    private let inventory = WindowInventory()
    private let monitor: ExclusionMonitor
    private let lock = NSLock()

    private var stream: DisplayStream?
    private var pipeline: DisplayPipeline?
    private var state = RecordingState.stopped

    public var onStateChange: (@Sendable (RecordingState) -> Void)?

    public init(core: any RemindCore, policy: ExclusionPolicy, settings: PipelineSettings = PipelineSettings()) {
        self.core = core
        self.settings = settings
        monitor = ExclusionMonitor(policy: policy, inventory: inventory)
    }

    public var currentState: RecordingState {
        lock.withLock { state }
    }

    public var pipelineStats: PipelineStats? {
        lock.withLock { pipeline }?.stats
    }

    public var framesDroppedForPrivacy: Int {
        monitor.framesDropped
    }

    /// The last frame kept, for showing immediately when the timeline opens.
    public var latestFrame: CVPixelBuffer? {
        lock.withLock { pipeline }?.latestFrame
    }

    /// Keeps the next frame even if it hasn't changed, for starring a moment.
    public func keepNextFrame() {
        lock.withLock { pipeline }?.keepNextFrame()
    }

    public func update(policy: ExclusionPolicy) {
        monitor.update(policy: policy)
    }

    /// The display under the pointer, or the main display.
    public static func activeDisplay() -> CGDirectDisplayID {
        let location = CGEvent(source: nil)?.location ?? .zero
        var display = CGDirectDisplayID()
        var count: UInt32 = 0
        if CGGetDisplaysWithPoint(location, 1, &display, &count) == .success, count > 0 {
            return display
        }
        return CGMainDisplayID()
    }

    public func start(displayID: CGDirectDisplayID = RecordingController.activeDisplay()) async throws {
        await stop()
        guard let uuid = ScreenContent.stableID(of: displayID) else {
            throw DisplayStreamError.displayNotFound(displayID)
        }
        let pipeline = try DisplayPipeline(core: core, displayUUID: uuid, settings: settings) { [weak self] frame in
            self?.decide(for: frame) ?? .drop(reason: "stopped")
        }
        let stream = DisplayStream(
            displayID: displayID,
            queue: pipeline.queue,
            onFrame: { [weak pipeline] frame in pipeline?.ingest(frame) },
            onStop: { [weak self] reason in self?.streamStopped(reason) }
        )
        try await monitor.start(stream)
        setState(.recording(displayID: displayID)) {
            self.stream = stream
            self.pipeline = pipeline
        }
    }

    public func stop() async {
        let stream = lock.withLock { () -> DisplayStream? in
            let stream = self.stream
            self.stream = nil
            self.pipeline = nil
            return stream
        }
        await stream?.stop()
        setState(.stopped) {}
    }

    private func setState(_ new: RecordingState, _ changes: () -> Void) {
        let callback = lock.withLock { () -> (@Sendable (RecordingState) -> Void)? in
            changes()
            state = new
            return onStateChange
        }
        callback?(new)
    }

    private func streamStopped(_ reason: StreamStop) {
        setState(.interrupted(reason)) {
            stream = nil
            pipeline = nil
        }
    }

    // MARK: Deciding

    /// Runs on the pipeline's queue, just before a frame would be encoded.
    private func decide(for frame: CapturedFrame) -> FrameDecision {
        let check = monitor.check(frameDisplayTime: frame.displayTime)
        guard check.verdict == .allow else {
            return .drop(reason: "\(check.verdict)")
        }
        return context(from: check.windows, displayBounds: CGDisplayBounds(frame.displayID), excluding: check.required)
    }

    /// A window's bounds as a fraction of the display. Both use a top-left origin.
    private static func normalized(_ bounds: CGRect, in display: CGRect) -> CGRect {
        guard display.width > 0, display.height > 0 else { return .zero }
        let clipped = bounds.intersection(display)
        return CGRect(
            x: (clipped.minX - display.minX) / display.width,
            y: (clipped.minY - display.minY) / display.height,
            width: clipped.width / display.width,
            height: clipped.height / display.height
        )
    }

    /// Works out what the frame shows: the frontmost ordinary window on this display.
    private func context(
        from windows: [WindowInfo],
        displayBounds: CGRect,
        excluding required: Set<CGWindowID>
    ) -> FrameDecision {
        guard let front = windows.first(where: {
            $0.layer == 0 && !required.contains($0.id) && $0.bounds.intersects(displayBounds)
        }) else {
            return .keep(FrameContext())
        }
        let identity = inventory.identify(front.ownerPID)
        var context = FrameContext(
            bundleID: identity.bundleID,
            window: front.title,
            frontRect: Self.normalized(front.bounds, in: displayBounds)
        )

        guard let family = identity.family else {
            return .keep(context)
        }
        switch AccessibilityProbe.frontWindow(pid: front.ownerPID, family: family) {
        case .success(let info):
            context.url = info.url
            context.window = info.title ?? context.window
            // Accessibility can reveal a title the window list didn't.
            if PrivateWindowRules.isPrivate(title: info.title, family: family) {
                return .drop(reason: "the front window is private")
            }
            return .keep(context)
        case .failure(.notTrusted), .failure(.noFocusedWindow):
            // Titles above already covered private windows, and only the URL is
            // lost here.
            return .keep(context)
        case .failure(.timedOut):
            // The browser didn't answer in time, so this can't be confirmed safe.
            return .drop(reason: "the browser didn't respond")
        }
    }
}
