import AppKit
import Capture
import CoreAPI
import CoreGraphics
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
    private let lock = NSLock()
    private let ownPID = ProcessInfo.processInfo.processIdentifier

    private var policy: ExclusionPolicy
    private var gate = ExclusionGate()
    private var filterUpdateInFlight = false
    private var stream: DisplayStream?
    private var pipeline: DisplayPipeline?
    private var state = RecordingState.stopped
    private var droppedForPrivacy = 0

    public var onStateChange: (@Sendable (RecordingState) -> Void)?

    public init(core: any RemindCore, policy: ExclusionPolicy, settings: PipelineSettings = PipelineSettings()) {
        self.core = core
        self.policy = policy
        self.settings = settings
    }

    public var currentState: RecordingState {
        lock.withLock { state }
    }

    public var pipelineStats: PipelineStats? {
        lock.withLock { pipeline }?.stats
    }

    public var framesDroppedForPrivacy: Int {
        lock.withLock { droppedForPrivacy }
    }

    public func update(policy: ExclusionPolicy) {
        lock.withLock { self.policy = policy }
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

        let required = currentRequiredExclusions()
        let appliedAt = try await stream.start(excluding: required)
        setState(.recording(displayID: displayID)) {
            self.stream = stream
            self.pipeline = pipeline
            self.gate.commit(required, at: appliedAt)
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

    private func currentRequiredExclusions() -> Set<CGWindowID> {
        let windows = inventory.onScreenWindows()
        let policy = lock.withLock { self.policy }
        var required = policy.requiredExclusions(in: windows) { inventory.identify($0) }
        // Remind's own windows never appear in a recording.
        for window in windows where window.ownerPID == ownPID {
            required.insert(window.id)
        }
        return required
    }

    /// Runs on the pipeline's queue, just before a frame would be encoded.
    private func decide(for frame: CapturedFrame) -> FrameDecision {
        let windows = inventory.onScreenWindows()
        let policy = lock.withLock { self.policy }
        var required = policy.requiredExclusions(in: windows) { inventory.identify($0) }
        for window in windows where window.ownerPID == ownPID {
            required.insert(window.id)
        }

        let verdict = lock.withLock { gate.check(required: required, frameDisplayTime: frame.displayTime) }
        switch verdict {
        case .allow:
            break
        case .dropNeedsFilter(let needed):
            refreshFilter(needed, displayID: frame.displayID)
            lock.withLock { droppedForPrivacy += 1 }
            return .drop(reason: "the filter doesn't cover a window yet")
        case .dropFrameTooOld:
            lock.withLock { droppedForPrivacy += 1 }
            return .drop(reason: "composed before the filter took effect")
        case .dropNoFilter:
            lock.withLock { droppedForPrivacy += 1 }
            return .drop(reason: "no filter yet")
        }

        return context(from: windows, displayBounds: CGDisplayBounds(frame.displayID), excluding: required, policy: policy)
    }

    private func refreshFilter(_ required: Set<CGWindowID>, displayID: CGDirectDisplayID) {
        let stream = lock.withLock { () -> DisplayStream? in
            guard !filterUpdateInFlight else { return nil }
            filterUpdateInFlight = true
            return self.stream
        }
        guard let stream else { return }
        Task { [weak self] in
            do {
                let appliedAt = try await stream.update(excluding: required)
                self?.lock.withLock {
                    self?.gate.commit(required, at: appliedAt)
                    self?.filterUpdateInFlight = false
                }
            } catch {
                self?.lock.withLock { self?.filterUpdateInFlight = false }
            }
        }
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
        excluding required: Set<CGWindowID>,
        policy: ExclusionPolicy
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
            if policy.excludesPrivateWindows, PrivateWindowRules.isPrivate(title: info.title, family: family) {
                return .drop(reason: "the front window is private")
            }
            return .keep(context)
        case .failure(.notTrusted), .failure(.noFocusedWindow):
            // Titles above already covered private windows, and only the URL is
            // lost here.
            return .keep(context)
        case .failure(.timedOut):
            // The browser didn't answer in time, so this can't be confirmed safe.
            return policy.excludesPrivateWindows ? .drop(reason: "the browser didn't respond") : .keep(context)
        }
    }
}
