import AppKit
import CoreAPI
import CoreVideo
import FrameEngine
import OverlayShell
import QuartzCore
import StripRenderer
import SwiftUI

/// Runs the timeline on one display: the frame, the strip, the controls, and input.
@MainActor
public final class TimelineController: NSObject {
    private let core: any RemindCore
    private let display: UUID
    private let scrub: ScrubEngine
    public let model = TimelineModel()

    public let rootView: NSView
    private let frameView: FrameLayerView
    private let inputView = OverlayInputView()
    private let stripView: StripView?
    private let playheadView: PlayheadView
    private var chromeHost: NSHostingView<AnyView>?

    private var interpreter = ScrollInterpreter(pointsPerSecond: TimelineZoom.defaultPointsPerSecond)
    /// Where the playhead is. This changes on every scroll event, so it stays out of
    /// the SwiftUI model.
    public private(set) var playhead = Date()
    private var timelineOrigin = Date()
    private var loadedRange: ClosedRange<Date>?
    private var loadedZoom = 0.0
    private var colors: [String: SIMD4<Float>] = [:]
    private var icons: [String: CGImage] = [:]
    private var needsStripDraw = true
    private var displayLink: CADisplayLink?
    private var shownFrameID: Int64?
    private var earliest: Date?

    public var onAction: ((OverlayAction) -> Void)?
    public var isSearchFocused: () -> Bool = { false } {
        didSet { inputView.isSearchFocused = isSearchFocused }
    }

    /// Called when a frame is shown, for anything drawn over it, such as highlights.
    public var onFrameShown: ((Int64, CVPixelBuffer) -> Void)?

    public init(core: any RemindCore, display: UUID, frame: NSRect) {
        self.core = core
        self.display = display
        scrub = ScrubEngine(core: core, display: display)
        frameView = FrameLayerView(frame: frame)
        stripView = StripView(stripFrame: NSRect(
            x: 0,
            y: TimelineMetrics.stripBottom,
            width: frame.width,
            height: TimelineMetrics.stripHeight
        ))
        playheadView = PlayheadView(frame: NSRect(
            x: (frame.width - 3) / 2,
            y: 0,
            width: 3,
            height: TimelineMetrics.playheadHeight
        ))
        let root = NSView(frame: frame)
        root.autoresizingMask = [.width, .height]
        root.wantsLayer = true
        rootView = root
        super.init()

        frameView.autoresizingMask = [.width, .height]
        root.addSubview(frameView)
        inputView.frame = frame
        inputView.autoresizingMask = [.width, .height]
        inputView.onAction = { [weak self] action in self?.handle(action) }
        root.addSubview(inputView)

        scrub.onUpdate = { [weak self] update in
            DispatchQueue.main.async {
                self?.show(update)
            }
        }
    }

    /// Sets the controls, drawn above the frame and below any panels.
    public func install<Chrome: View>(chrome: Chrome) {
        let host = NSHostingView(rootView: AnyView(chrome))
        host.frame = rootView.bounds
        host.autoresizingMask = [.width, .height]
        // The scrim sits under the strip, so it's added first.
        rootView.addSubview(host, positioned: .above, relativeTo: inputView)
        chromeHost = host
        if let stripView {
            stripView.autoresizingMask = [.width]
            rootView.addSubview(stripView, positioned: .above, relativeTo: host)
        }
        playheadView.autoresizingMask = [.minXMargin, .maxXMargin]
        rootView.addSubview(playheadView, positioned: .above, relativeTo: stripView ?? host)
    }

    /// The view that should receive keys when nothing else has focus.
    public var keyView: NSView { inputView }

    /// Starts showing history from a moment, with the picture already on screen if
    /// there's one to hand, so opening feels instant.
    public func present(at time: Date, immediate: CVPixelBuffer? = nil) {
        interpreter.reset()
        if let immediate {
            frameView.show(immediate)
        }
        playhead = clamped(time)
        model.playheadMoved(to: playhead)
        reloadStrip()
        startDisplayLink()
        scrub.seek(.init(time: playhead, velocity: 0))
    }

    public func stop() {
        displayLink?.invalidate()
        displayLink = nil
        interpreter.reset()
    }

    /// Frees decoded frames, as when memory is short.
    public func purge() {
        scrub.purge()
    }

    // MARK: Moving through time

    /// Moves the playhead, which updates everything on the next display refresh.
    public func move(to time: Date, velocity: Double = 0) {
        playhead = clamped(time)
        model.playheadMoved(to: playhead)
        needsStripDraw = true
        scrub.seek(.init(time: playhead, velocity: velocity))
        reloadStripIfNeeded()
    }

    private func clamped(_ time: Date) -> Date {
        let now = model.now()
        var result = min(time, now)
        if let earliest { result = max(result, earliest) }
        return result
    }

    private func handle(_ action: OverlayAction) {
        switch action {
        case .scroll(let input):
            let seconds = interpreter.seconds(for: input)
            // In frames per second, since frames are about 2 seconds apart.
            let framesPerSecond = interpreter.velocity / 2
            move(to: playhead.addingTimeInterval(seconds), velocity: framesPerSecond)
        case .scrollEnded:
            interpreter.reset()
        case .zoom(let magnification):
            interpreter.pointsPerSecond = TimelineZoom.applying(
                magnification: magnification,
                to: interpreter.pointsPerSecond
            )
            needsStripDraw = true
            reloadStripIfNeeded()
        case .stepFrame(let forward):
            step(forward: forward)
        case .stepRun(let forward):
            stepRun(forward: forward)
        default:
            onAction?(action)
        }
    }

    private func step(forward: Bool) {
        guard let current = shownFrameID,
              let next = try? core.neighbour(of: current, forward: forward)
        else { return }
        move(to: next.capturedAt)
    }

    private func stepRun(forward: Bool) {
        let end = playhead.addingTimeInterval(forward ? 86_400 : -86_400)
        guard let data = try? core.timeline(
            display: display,
            from: min(playhead, end),
            to: max(playhead, end),
            minimumDuration: 0
        ) else { return }
        if forward {
            if let next = data.runs.first(where: { $0.start > playhead }) {
                move(to: next.start)
            }
        } else if let current = data.runs.last(where: { $0.start < playhead }) {
            // Going back first returns to the start of the current run.
            let target = playhead.timeIntervalSince(current.start) > 1
                ? current.start
                : data.runs.last(where: { $0.start < current.start })?.start
            if let target { move(to: target) }
        }
    }

    private func show(_ update: ScrubUpdate) {
        frameView.show(update.frame.buffer)
        guard update.frame.frameID != shownFrameID else { return }
        shownFrameID = update.frame.frameID
        onFrameShown?(update.frame.frameID, update.frame.buffer)
        let core = self.core
        let frameID = update.frame.frameID
        Task.detached(priority: .userInitiated) { [weak self] in
            let context = try? core.frameContext(of: frameID)
            await self?.model.showContext(context ?? nil)
        }
    }

    // MARK: The strip

    private func startDisplayLink() {
        guard displayLink == nil else { return }
        let link = rootView.displayLink(target: self, selector: #selector(tick))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    @objc private func tick() {
        guard needsStripDraw, let stripView else { return }
        needsStripDraw = false
        stripView.draw(viewport: currentViewport())
    }

    private func currentViewport() -> StripViewport {
        StripViewport(
            center: playhead.timeIntervalSince(timelineOrigin),
            pointsPerSecond: interpreter.pointsPerSecond,
            widthPoints: Double(rootView.bounds.width),
            heightPoints: Double(TimelineMetrics.stripHeight),
            capsuleHeightPoints: 9
        )
    }

    private func reloadStripIfNeeded() {
        let visible = Double(rootView.bounds.width) / interpreter.pointsPerSecond
        let needsData: Bool
        if let loadedRange {
            let margin = visible * 0.5
            needsData = playhead.addingTimeInterval(-margin) < loadedRange.lowerBound
                || playhead.addingTimeInterval(margin) > loadedRange.upperBound
                || abs(interpreter.pointsPerSecond - loadedZoom) / loadedZoom > 0.3
        } else {
            needsData = true
        }
        if needsData { reloadStrip() }
    }

    private func reloadStrip() {
        let pixels = Double(rootView.bounds.width)
        let pointsPerSecond = interpreter.pointsPerSecond
        let span = pixels / pointsPerSecond
        let from = playhead.addingTimeInterval(-span * 1.5)
        let to = playhead.addingTimeInterval(span * 1.5)
        loadedRange = from...to
        loadedZoom = pointsPerSecond
        let core = self.core
        let display = self.display
        Task.detached(priority: .userInitiated) { [weak self] in
            // One point of strip is the smallest thing worth keeping.
            guard let data = try? core.timeline(
                display: display, from: from, to: to, minimumDuration: 1 / pointsPerSecond
            ) else { return }
            await self?.apply(data, origin: from)
        }
    }

    private func apply(_ data: TimelineData, origin: Date) {
        timelineOrigin = origin
        let palette = data.apps.map(color(for:))
        let images = data.apps.map(icon(for:))
        let runs = data.runs.map { run in
            StripRun(
                start: Float(run.start.timeIntervalSince(origin)),
                end: Float(run.end.timeIntervalSince(origin)),
                color: palette[run.app]
            )
        }
        let icons = zip(runs, data.runs).compactMap { strip, run in
            images[run.app].map { StripIcon(start: strip.start, end: strip.end, image: $0) }
        }
        stripView?.setRuns(runs, icons: icons)
        if let first = data.runs.first, earliest == nil {
            earliest = first.start
        }
        needsStripDraw = true
    }

    private func icon(for bundleID: String?) -> CGImage? {
        guard let bundleID else { return nil }
        if let known = icons[bundleID] { return known }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        var rect = CGRect(x: 0, y: 0, width: 48, height: 48)
        let image = NSWorkspace.shared.icon(forFile: url.path).cgImage(forProposedRect: &rect, context: nil, hints: nil)
        icons[bundleID] = image
        return image
    }

    private func color(for bundleID: String?) -> SIMD4<Float> {
        guard let bundleID else { return SIMD4(0.55, 0.57, 0.6, 1) }
        if let known = colors[bundleID] { return known }
        let color = AppColors.stripColor(forBundleID: bundleID)
        colors[bundleID] = color
        return color
    }
}
