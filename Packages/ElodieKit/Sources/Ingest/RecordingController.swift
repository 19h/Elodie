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
    case interrupted(CaptureStop)
}

/// Why private windows might not be spotted right now.
public enum PrivacyCheckTrouble: Sendable, Equatable {
    /// Without Accessibility, only window titles can reveal private windows.
    case accessibilityOff
    /// A browser isn't answering, so its windows are being left out until it does.
    case browserNotResponding(bundleID: String)
}

/// Decides when capture should move to another display. The pointer often crosses a
/// display briefly, and restarting capture isn't free, so it has to stay a moment.
public struct DisplayFollower: Sendable {
    public static let settleTime: TimeInterval = 2
    private var candidate: (display: CGDirectDisplayID, since: Date)?

    public init() {}

    /// Returns the display to move to, if it's time to move.
    public mutating func observe(
        pointerOn display: CGDirectDisplayID,
        current: CGDirectDisplayID,
        now: Date
    ) -> CGDirectDisplayID? {
        guard display != current else {
            candidate = nil
            return nil
        }
        guard let candidate, candidate.display == display else {
            self.candidate = (display, now)
            return nil
        }
        guard now.timeIntervalSince(candidate.since) >= Self.settleTime else { return nil }
        self.candidate = nil
        return display
    }
}

/// Runs capture for the display the pointer is on.
///
/// It decides what's safe to keep: which windows each picture may show, and whether the
/// picture is still safe once it exists. See `WindowChooser`.
public final class RecordingController: @unchecked Sendable {
    private let core: any ElodieCore
    private let settings: PipelineSettings
    private let inventory = WindowInventory()
    private let chooser: WindowChooser
    private let readFrontWindow: FrontWindowReader
    private let lock = NSLock()

    private var capture: DisplayCapture?
    private var pipeline: DisplayPipeline?
    private var state = RecordingState.stopped
    private var trouble: PrivacyCheckTrouble?
    private var browserTimeouts = 0
    private var follower = DisplayFollower()
    private var followTimer: DispatchSourceTimer?
    private var isMoving = false
    private var powerObserver: (any NSObjectProtocol)?
    private var lastChange: Task<Void, any Error>?

    public var onStateChange: (@Sendable (RecordingState) -> Void)?

    /// - Parameter readFrontWindow: how to read a browser's front window. Without one, only
    ///   the window list is known.
    public init(
        core: any ElodieCore,
        policy: ExclusionPolicy,
        settings: PipelineSettings = PipelineSettings(),
        readFrontWindow: @escaping FrontWindowReader = { _, _ in .failure(.notTrusted) }
    ) {
        self.core = core
        self.settings = settings
        self.readFrontWindow = readFrontWindow
        chooser = WindowChooser(policy: policy, inventory: inventory)
    }

    deinit {
        followTimer?.cancel()
        if let powerObserver {
            NotificationCenter.default.removeObserver(powerObserver)
        }
    }

    /// Why private windows might not be spotted right now.
    public var privacyCheckTrouble: PrivacyCheckTrouble? {
        lock.withLock { trouble }
    }

    public var currentState: RecordingState {
        lock.withLock { state }
    }

    public var pipelineStats: PipelineStats? {
        lock.withLock { pipeline }?.stats
    }

    public var framesDroppedForPrivacy: Int {
        chooser.framesDropped
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
        chooser.update(policy: policy)
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

    /// Starts capture on a display, replacing what's running. Starting and stopping happen
    /// strictly one at a time and in the order asked for, however they overlap, so a pause
    /// that arrives during a start really does end up paused.
    public func start(displayID: CGDirectDisplayID = RecordingController.activeDisplay()) async throws {
        try await enqueue { controller in
            try await controller.performStart(displayID: displayID)
        }.value
    }

    public func stop() async {
        _ = await enqueue { controller in
            await controller.performStop()
        }.result
    }

    private func enqueue(
        _ work: @escaping @Sendable (RecordingController) async throws -> Void
    ) -> Task<Void, any Error> {
        lock.withLock {
            let previous = lastChange
            let task = Task<Void, any Error> { [self] in
                _ = await previous?.result
                try await work(self)
            }
            lastChange = task
            return task
        }
    }

    private func performStart(displayID: CGDirectDisplayID) async throws {
        await stopCapture()
        guard let uuid = ScreenContent.stableID(of: displayID) else {
            throw DisplayCaptureError.displayNotFound(displayID)
        }
        let pipeline = try DisplayPipeline(core: core, displayUUID: uuid, settings: settings) { [weak self] frame in
            self?.decide(for: frame) ?? .drop(reason: "stopped")
        }
        let capture = DisplayCapture(
            displayID: displayID,
            queue: pipeline.queue,
            onFrame: { [weak pipeline] frame in pipeline?.ingest(frame) },
            onStop: { [weak self] reason in self?.captureStopped(reason, displayID: displayID) }
        )
        pipeline.onEncoderFailure = { [weak self] in self?.encoderKeptFailing() }
        let interval = ProcessInfo.processInfo.isLowPowerModeEnabled
            ? DisplayCapture.lowPowerInterval
            : DisplayCapture.captureInterval
        // In place first, because a stop reported straight away has to be recognised as this one.
        lock.withLock {
            self.capture = capture
            self.pipeline = pipeline
        }
        do {
            try capture.start(interval: interval) { [chooser] in chooser.windowsToCapture() }
        } catch {
            lock.withLock {
                self.capture = nil
                self.pipeline = nil
            }
            throw error
        }
        guard lock.withLock({ self.capture === capture }) else { return }
        setState(.recording(displayID: displayID)) {}
        beginFollowing()
    }

    private func performStop() async {
        endFollowing()
        await stopCapture()
    }

    private func stopCapture() async {
        let capture = lock.withLock { () -> DisplayCapture? in
            let capture = self.capture
            self.capture = nil
            self.pipeline = nil
            return capture
        }
        await capture?.stop()
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

    /// Capture that has already been replaced can still report stopping. That says nothing
    /// about what's running now.
    private func captureStopped(_ reason: CaptureStop, displayID: CGDirectDisplayID) {
        let isCurrent = lock.withLock { capture?.displayID == displayID }
        guard isCurrent else { return }
        endFollowing()
        setState(.interrupted(reason)) {
            capture = nil
            pipeline = nil
        }
    }

    private func encoderKeptFailing() {
        Task { [weak self] in
            await self?.stop()
            self?.setState(.interrupted(.encoderFailed)) {}
        }
    }

    // MARK: Following the pointer

    private func beginFollowing() {
        lock.withLock {
            guard followTimer == nil else { return }
            follower = DisplayFollower()
            let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
            timer.schedule(deadline: .now() + 1, repeating: 1, leeway: .milliseconds(250))
            timer.setEventHandler { [weak self] in self?.checkPointer() }
            timer.resume()
            followTimer = timer
        }
        if powerObserver == nil {
            // Low Power Mode changes how often frames are captured.
            powerObserver = NotificationCenter.default.addObserver(
                forName: .NSProcessInfoPowerStateDidChange,
                object: nil,
                queue: nil
            ) { [weak self] _ in
                guard let self, case .recording(let display) = self.currentState else { return }
                self.move(to: display)
            }
        }
    }

    private func endFollowing() {
        lock.withLock {
            followTimer?.cancel()
            followTimer = nil
        }
    }

    private func checkPointer() {
        guard case .recording(let current) = currentState else { return }
        let target = lock.withLock {
            isMoving ? nil : follower.observe(pointerOn: Self.activeDisplay(), current: current, now: Date())
        }
        if let target { move(to: target) }
    }

    /// Restarts capture on a display. If that fails, it says so instead of quietly
    /// recording nothing.
    private func move(to display: CGDirectDisplayID) {
        let proceed = lock.withLock { () -> Bool in
            guard !isMoving else { return false }
            isMoving = true
            return true
        }
        guard proceed else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.start(displayID: display)
            } catch {
                self.setState(.interrupted(CaptureStop(error))) {}
            }
            self.lock.withLock { self.isMoving = false }
        }
    }

    // MARK: Deciding

    /// Runs on the pipeline's queue, just before a frame would be encoded.
    private func decide(for frame: CapturedFrame) -> FrameDecision {
        let check = chooser.check(captured: frame.windows)
        guard check.isSafe else {
            return .drop(reason: "a window in the picture has to be hidden")
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

    private enum BrowserCheck {
        case answered
        case notTrusted
        case timedOut(bundleID: String)
    }

    /// One slow answer is normal, so a browser only counts as not responding after
    /// several in a row.
    private func noteBrowserCheck(_ check: BrowserCheck) {
        lock.withLock {
            switch check {
            case .answered:
                browserTimeouts = 0
                trouble = nil
            case .notTrusted:
                trouble = .accessibilityOff
            case .timedOut(let bundleID):
                browserTimeouts += 1
                if browserTimeouts >= 5 {
                    trouble = .browserNotResponding(bundleID: bundleID)
                }
            }
        }
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
        switch readFrontWindow(front.ownerPID, family) {
        case .success(let info):
            noteBrowserCheck(.answered)
            context.url = info.url
            context.window = info.title ?? context.window
            // Accessibility can reveal a title the window list didn't.
            if info.isMarkedPrivate || PrivateWindowRules.isPrivate(title: info.title, family: family) {
                return .drop(reason: "the front window is private")
            }
            return .keep(context)
        case .failure(.notTrusted):
            // Titles above already covered private windows, and only the URL is
            // lost here. The Screen settings tab explains what that means.
            noteBrowserCheck(.notTrusted)
            // Arc doesn't say so in its titles, so without this there's no way to tell.
            guard family != .arc else {
                return .drop(reason: "Arc's private windows can't be spotted without Accessibility")
            }
            return .keep(context)
        case .failure(.noFocusedWindow):
            noteBrowserCheck(.answered)
            return .keep(context)
        case .failure(.timedOut), .failure(.failed):
            // The browser didn't answer properly, so this can't be confirmed safe.
            noteBrowserCheck(.timedOut(bundleID: identity.bundleID ?? ""))
            return .drop(reason: "the browser didn't respond")
        }
    }
}
