import AppKit
import CoreAPI
import CoreImage
import CoreVideo
import FrameEngine
import OverlayShell
import QuartzCore
import StripRenderer
import SwiftUI

/// Runs the timeline on one display: the frame, the strip, the controls, and input.
@MainActor
public final class TimelineController: NSObject, NSDraggingSource {
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
    private var shownBuffer: CVPixelBuffer?
    private var earliest: Date?
    /// The lines on the frame being shown, once something has asked for them.
    private var lines: [RecognizedLine]?
    private var selected: [RecognizedLine] = []
    private var dragStart: CGPoint?
    private var dragKind = DragKind.none
    private var firstFrameHandler: (() -> Void)?

    private enum DragKind {
        case none
        /// Started on text, so it selects.
        case selecting
        /// Started off text, so it may pick up the whole frame.
        case pending
    }

    /// Where copied text goes. Tests use their own.
    public var pasteboard = NSPasteboard.general

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
        inputView.onMouse = { [weak self] mouse in self?.handle(mouse) }
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
        setStripVisible(false)
    }

    private func setStripVisible(_ visible: Bool) {
        stripView?.alphaValue = visible ? 1 : 0
        playheadView.alphaValue = visible ? 1 : 0
    }

    /// The view that should receive keys when nothing else has focus.
    public var keyView: NSView { inputView }

    /// Starts showing history from a moment, with the picture already on screen if
    /// there's one to hand, so opening feels instant.
    public func present(at time: Date, immediate: CVPixelBuffer? = nil, onFirstFrame: (() -> Void)? = nil) {
        interpreter.reset()
        model.isEmpty = false
        if let immediate {
            frameView.show(immediate)
            onFirstFrame?()
        } else {
            firstFrameHandler = onFirstFrame
            // Nothing may be recorded here, so this doesn't wait long for a frame.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                self?.deliverFirstFrame()
            }
        }
        riseChrome()
        // Long enough for a first frame, so this doesn't flash on every open.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let self, self.displayLink != nil else { return }
            if self.shownFrameID == nil { self.model.isEmpty = true }
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
        frameView.clear()
        shownFrameID = nil
        shownBuffer = nil
        lines = nil
        selected = []
        firstFrameHandler = nil
        model.isJumpToDateOpen = false
        // Hidden now, so nothing from this time can flash up at the start of the next.
        model.isChromeVisible = false
        setStripVisible(false)
        // Decoded frames can run to a gigabyte, and this may not open again for hours.
        scrub.purge()
    }

    private func deliverFirstFrame() {
        let handler = firstFrameHandler
        firstFrameHandler = nil
        handler?()
    }

    /// The frame stops first. Only then do the controls rise, which is the app's one flourish.
    private func riseChrome() {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            model.isChromeVisible = true
            setStripVisible(true)
            return
        }
        DispatchQueue.main.async { [weak self] in
            withAnimation(.easeOut(duration: 0.16)) {
                self?.model.isChromeVisible = true
            }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.16
                self?.stripView?.animator().alphaValue = 1
                self?.playheadView.animator().alphaValue = 1
            }
        }
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
        case .copy:
            copySelection()
        default:
            onAction?(action)
        }
    }

    // MARK: Text and dragging

    private func normalized(_ point: NSPoint) -> CGPoint {
        CGPoint(
            x: point.x / max(inputView.bounds.width, 1),
            y: 1 - point.y / max(inputView.bounds.height, 1)
        )
    }

    private func currentLines() -> [RecognizedLine] {
        if let lines { return lines }
        guard let shownFrameID else { return [] }
        let loaded = (try? core.frameLines(of: shownFrameID)) ?? []
        lines = loaded
        return loaded
    }

    private func handle(_ mouse: OverlayMouse) {
        switch mouse {
        case .moved(let point):
            let onText = TextSelection.line(at: normalized(point), in: lines ?? []) != nil
            (onText ? NSCursor.iBeam : NSCursor.arrow).set()
        case .down(let point):
            let start = normalized(point)
            dragStart = start
            setSelection([])
            model.isJumpToDateOpen = false
            dragKind = TextSelection.line(at: start, in: currentLines()) != nil ? .selecting : .pending
        case .dragged(let point, let event):
            guard let dragStart else { return }
            let current = normalized(point)
            switch dragKind {
            case .selecting:
                setSelection(TextSelection.lines(currentLines(), between: dragStart, and: current))
            case .pending:
                let size = inputView.bounds.size
                if hypot((current.x - dragStart.x) * size.width, (current.y - dragStart.y) * size.height) > 6 {
                    dragKind = .none
                    beginFrameDrag(event)
                }
            case .none:
                break
            }
        case .up:
            dragStart = nil
            dragKind = .none
        }
    }

    private func setSelection(_ lines: [RecognizedLine]) {
        selected = lines
        frameView.showSelection(lines.map(\.rect))
    }

    /// Copies what's selected, or everything on the frame when nothing is.
    public func copySelection() {
        let text = TextSelection.text(of: selected.isEmpty ? currentLines() : selected)
        guard !text.isEmpty else { return }
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    /// The frame on screen as an image.
    public func currentImage() -> NSImage? {
        guard let shownBuffer else { return nil }
        let image = CIImage(cvPixelBuffer: shownBuffer)
        guard let cgImage = Self.imageContext.createCGImage(image, from: image.extent) else { return nil }
        return NSImage(cgImage: cgImage, size: .zero)
    }

    private static let imageContext = CIContext()

    /// Lets the frame be dragged to Finder or another app, as a copy.
    private func beginFrameDrag(_ event: NSEvent) {
        guard let image = currentImage(),
              let tiff = image.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
        else { return }
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "remind-drag-\(UUID().uuidString)", directoryHint: .isDirectory)
        let url = directory.appending(path: "Remind \(Self.fileDate(playhead)).png")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try png.write(to: url)
        } catch {
            return
        }
        dragDirectory = directory

        let item = NSDraggingItem(pasteboardWriter: url as NSURL)
        let width: CGFloat = 320
        let aspect = image.size.height / max(image.size.width, 1)
        let origin = inputView.convert(event.locationInWindow, from: nil)
        item.setDraggingFrame(
            NSRect(x: origin.x - width / 2, y: origin.y - width * aspect / 2, width: width, height: width * aspect),
            contents: image
        )
        inputView.beginDraggingSession(with: [item], event: event, source: self)
    }

    private var dragDirectory: URL?

    private static func fileDate(_ date: Date) -> String {
        date.formatted(.iso8601.year().month().day().dateTimeSeparator(.space).time(includingFractionalSeconds: false))
            .replacingOccurrences(of: ":", with: "-")
    }

    public func draggingSession(
        _ session: NSDraggingSession,
        sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        .copy
    }

    /// The copy is unencrypted, so it doesn't stay behind. Receivers can take a moment to
    /// read the file after the drop.
    public func draggingSession(
        _ session: NSDraggingSession,
        endedAt screenPoint: NSPoint,
        operation: NSDragOperation
    ) {
        guard let directory = dragDirectory else { return }
        dragDirectory = nil
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 60) {
            try? FileManager.default.removeItem(at: directory)
        }
    }

    /// Grows the frame out of a search result as it's selected.
    public func flyIn(from rect: CGRect) {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        // SwiftUI's rects have their origin at the top left, and this view's at the bottom.
        frameView.flyIn(from: NSRect(
            x: rect.minX,
            y: rootView.bounds.height - rect.maxY,
            width: rect.width,
            height: rect.height
        ))
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
        shownBuffer = update.frame.buffer
        model.isEmpty = false
        deliverFirstFrame()
        guard update.frame.frameID != shownFrameID else { return }
        shownFrameID = update.frame.frameID
        lines = nil
        if !selected.isEmpty { setSelection([]) }
        if update.isExact { loadLinesSoon(for: update.frame.frameID) }
        onFrameShown?(update.frame.frameID, update.frame.buffer)
        let core = self.core
        let frameID = update.frame.frameID
        Task.detached(priority: .userInitiated) { [weak self] in
            let context = try? core.frameContext(of: frameID)
            await self?.model.showContext(context ?? nil)
        }
    }

    /// Reads the frame's text once the playhead has rested on it, so the cursor can show
    /// where text is. Skipped while scrubbing, when it would never be used.
    private func loadLinesSoon(for frameID: Int64) {
        let core = self.core
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard let self, self.shownFrameID == frameID, self.lines == nil else { return }
            let loaded = await Task.detached(priority: .userInitiated) {
                (try? core.frameLines(of: frameID)) ?? []
            }.value
            if self.shownFrameID == frameID { self.lines = loaded }
        }
    }

    // MARK: The strip

    /// Called the next time the strip reaches the screen, for measuring how fast opening is.
    public func onNextStripPresent(_ handler: @escaping @Sendable (CFTimeInterval) -> Void) {
        stripView?.onNextPresent = handler
        needsStripDraw = true
    }

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
