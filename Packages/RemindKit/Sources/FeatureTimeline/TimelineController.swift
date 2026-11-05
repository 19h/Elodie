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
    /// The display whose history is being shown, which needn't be the one this is on.
    public private(set) var display: UUID
    private var scrub: ScrubEngine
    public let model = TimelineModel()

    public let rootView: NSView
    private let frameView: FrameLayerView
    private let inputView = OverlayInputView()
    private let stripView: StripView?
    private let stripInput: StripInteractionView
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
    /// The first moment recorded on this display, once it's known. Nothing before it exists.
    private var earliest: Date?
    /// What the strip is drawing, for working out what the pointer is over.
    private var runs: [TimelineRun] = []
    private var apps: [String?] = []
    private var stars: [StarredFrame] = []
    private var speech: [DateInterval] = []
    private var editor = SliceEditor()
    private var hoverGeneration = 0
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
    /// Called when someone moves the playhead themselves, as opposed to being taken somewhere.
    public var onUserMoved: (() -> Void)?

    public init(core: any RemindCore, display: UUID, frame: NSRect) {
        self.core = core
        self.display = display
        scrub = ScrubEngine(core: core, display: display)
        frameView = FrameLayerView(frame: frame)
        let stripFrame = NSRect(
            x: 0,
            y: TimelineMetrics.stripBottom,
            width: frame.width,
            height: TimelineMetrics.stripHeight
        )
        stripView = StripView(stripFrame: stripFrame)
        stripInput = StripInteractionView(frame: stripFrame)
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

        stripInput.onEvent = { [weak self] event in self?.handle(strip: event) }
        stripInput.onScroll = { [weak self] event in self?.inputView.scrollWheel(with: event) }
        stripInput.onMagnify = { [weak self] event in self?.inputView.magnify(with: event) }

        connectScrub()
    }

    private func connectScrub() {
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
        stripInput.autoresizingMask = [.width]
        rootView.addSubview(stripInput, positioned: .above, relativeTo: stripView ?? host)
        playheadView.autoresizingMask = [.minXMargin, .maxXMargin]
        rootView.addSubview(playheadView, positioned: .above, relativeTo: stripInput)
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
        model.zoomFraction = TimelineZoom.fraction(for: interpreter.pointsPerSecond)
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
        loadBounds()
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
        editor.clear()
        // Hidden now, so nothing from this time can flash up at the start of the next.
        model.reset()
        setStripVisible(false)
        applyOverlays()
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

    // MARK: Which display

    /// Shows the history of another display here. Recording follows the pointer, so what
    /// someone's looking for can be from a different display than the one they're at.
    public func showDisplay(_ newDisplay: UUID) {
        guard newDisplay != display else { return }
        display = newDisplay
        scrub.onUpdate = nil
        scrub = ScrubEngine(core: core, display: newDisplay)
        connectScrub()
        earliest = nil
        runs = []
        apps = []
        stars = []
        speech = []
        shownFrameID = nil
        // What was loaded belongs to the other display.
        loadedRange = nil
        clearSlice()
        loadBounds()
    }

    /// Moves to another display from the picker, keeping to the same moment if it can.
    public func chooseDisplay(_ newDisplay: UUID) {
        onUserMoved?()
        showDisplay(newDisplay)
        move(to: playhead)
    }

    /// What a display is called, supplied by whoever knows what's connected.
    public var displayName: (RecordedDisplay) -> String = { "\($0.width) × \($0.height)" }

    private func loadBounds() {
        let core = self.core
        let display = self.display
        Task.detached(priority: .userInitiated) { [weak self] in
            let displays = (try? core.displays()) ?? []
            await self?.setDisplays(displays, for: display)
        }
    }

    private func setDisplays(_ displays: [RecordedDisplay], for forDisplay: UUID) {
        guard forDisplay == display else { return }
        earliest = displays.first { $0.id == display }?.first
        model.shownDisplay = display
        model.recordedDisplays = displays.count > 1
            ? displays.map { DisplayChoice(id: $0.id, name: displayName($0)) }
            : []
    }

    /// Hands the keyboard back to the timeline, after something that had it has closed.
    public func restoreKeyFocus() {
        rootView.window?.makeFirstResponder(inputView)
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
            onUserMoved?()
            move(to: playhead.addingTimeInterval(seconds), velocity: framesPerSecond)
        case .scrollEnded:
            interpreter.reset()
        case .zoom(let magnification):
            setZoom(pointsPerSecond: TimelineZoom.applying(
                magnification: magnification,
                to: interpreter.pointsPerSecond
            ))
        case .zoomIn:
            setZoom(pointsPerSecond: interpreter.pointsPerSecond * 1.5)
        case .zoomOut:
            setZoom(pointsPerSecond: interpreter.pointsPerSecond / 1.5)
        case .stepFrame(let forward):
            onUserMoved?()
            step(forward: forward)
        case .stepRun(let forward):
            onUserMoved?()
            stepRun(forward: forward)
        case .copy:
            copySelection()
        case .deleteSelection:
            if model.slice != nil {
                model.isConfirmingDelete = true
            }
        default:
            onAction?(action)
        }
    }

    // MARK: Zoom

    /// Sets the zoom from the control, where 0 is widest and 1 is closest.
    public func setZoom(fraction: Double) {
        setZoom(pointsPerSecond: TimelineZoom.pointsPerSecond(forFraction: fraction))
    }

    private func setZoom(pointsPerSecond: Double) {
        interpreter.pointsPerSecond = min(
            max(pointsPerSecond, TimelineZoom.minimumPointsPerSecond),
            TimelineZoom.maximumPointsPerSecond
        )
        model.zoomFraction = TimelineZoom.fraction(for: interpreter.pointsPerSecond)
        needsStripDraw = true
        reloadStripIfNeeded()
    }

    /// Fills the strip with what's selected.
    public func zoomToSlice() {
        guard let slice = model.slice, slice.duration > 0 else { return }
        setZoom(pointsPerSecond: Double(rootView.bounds.width) * 0.7 / slice.duration)
        move(to: slice.start.addingTimeInterval(slice.duration / 2))
    }

    // MARK: The strip, under the mouse

    private var geometry: StripGeometry {
        StripGeometry(
            center: playhead,
            pointsPerSecond: interpreter.pointsPerSecond,
            width: Double(rootView.bounds.width)
        )
    }

    private var selectableRange: ClosedRange<Date> {
        let now = model.now()
        return min(earliest ?? .distantPast, now)...now
    }

    private func handle(strip event: StripInteractionView.Event) {
        switch event {
        case .moved(let x):
            (editor.isOverHandle(x: x, geometry: geometry) ? NSCursor.resizeLeftRight : NSCursor.arrow).set()
            updateHover(x: x)
        case .exited:
            hoverGeneration += 1
            NSCursor.arrow.set()
            model.hover = nil
            applyOverlays()
        case .down(let x, _):
            model.hover = nil
            editor.mouseDown(x: x, geometry: geometry)
        case .dragged(let x):
            editor.mouseDragged(x: x, geometry: geometry, runs: runs, limits: selectableRange)
            model.setSlice(editor.selection)
            applyOverlays()
        case .up(let x):
            let outcome = editor.mouseUp(x: x, geometry: geometry)
            switch outcome {
            case .clicked(let time):
                click(at: time)
            case .selected:
                sliceChanged()
            case .nothing:
                break
            }
        }
    }

    /// A click goes to that moment, and picks out the run it's in, ready to be managed.
    private func click(at time: Date) {
        onUserMoved?()
        move(to: time)
        if let run = SliceEditor.run(at: time, in: runs) {
            let now = model.now()
            editor.select(DateInterval(start: run.start, end: max(min(run.end, now), run.start)))
        } else {
            editor.clear()
        }
        sliceChanged()
    }

    private func sliceChanged() {
        model.setSlice(editor.selection)
        applyOverlays()
        guard let slice = editor.selection else { return }
        let core = self.core
        Task.detached(priority: .userInitiated) { [weak self] in
            let summary = try? core.sliceSummary(from: slice.start, to: slice.end)
            await self?.showSummary(summary, for: slice)
        }
    }

    private func showSummary(_ summary: SliceSummary?, for slice: DateInterval) {
        guard model.slice == slice else { return }
        model.setSliceSummary(summary)
    }

    /// Picks out a stretch from outside the strip.
    public func select(_ slice: DateInterval) {
        editor.select(slice)
        sliceChanged()
    }

    public func clearSlice() {
        editor.clear()
        model.setSlice(nil)
        applyOverlays()
    }

    private func updateHover(x: Double) {
        let time = geometry.time(atX: x)
        guard let run = SliceEditor.run(at: time, in: runs) else {
            hoverGeneration += 1
            if model.hover != nil {
                model.hover = nil
                applyOverlays()
            }
            return
        }
        let bundleID = apps.indices.contains(run.app) ? apps[run.app] : nil
        // Keep what's known about this run while the details for this spot are read.
        let previous = model.hover
        let sameRun = previous?.start == run.start
        model.hover = StripHover(
            x: x,
            start: run.start,
            end: run.end,
            bundleID: bundleID,
            window: sameRun ? previous?.window : nil,
            url: sameRun ? previous?.url : nil
        )
        applyOverlays()

        hoverGeneration += 1
        let generation = hoverGeneration
        let core = self.core
        let display = self.display
        Task.detached(priority: .userInitiated) { [weak self] in
            let segment = try? core.segment(display: display, at: time)
            await self?.showHoverDetails(segment, generation: generation)
        }
    }

    private func showHoverDetails(_ segment: SegmentDetails?, generation: Int) {
        guard generation == hoverGeneration, let segment else { return }
        model.hover?.window = segment.window
        model.hover?.url = segment.url
    }

    private func applyOverlays() {
        func seconds(_ date: Date) -> Float { Float(date.timeIntervalSince(timelineOrigin)) }
        func range(_ start: Date, _ end: Date) -> ClosedRange<Float> {
            let from = seconds(start)
            return from...max(from, seconds(end))
        }
        stripView?.setOverlays(StripOverlays(
            hovered: model.hover.map { range($0.start, $0.end) },
            selection: editor.selection.map { range($0.start, $0.end) },
            stars: stars.map { seconds($0.time) },
            speech: speech.map { range($0.start, $0.end) }
        ))
        needsStripDraw = true
    }

    /// Stars were added or removed, so the strip's marks need reading again.
    public func reloadMarks() {
        reloadStrip()
    }

    /// Forgets decoded pictures, for a display that's not on show.
    public func forgetFrames() {
        scrub.forgetEverything()
    }

    /// Recordings were deleted, so what's on show may no longer exist.
    public func recordingsChanged() {
        scrub.forgetEverything()
        shownFrameID = nil
        shownBuffer = nil
        lines = nil
        editor.clear()
        model.setSlice(nil)
        loadedRange = nil
        loadBounds()
        reloadStrip()
        scrub.seek(.init(time: playhead, velocity: 0))
        applyOverlays()
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
            model.isZoomOpen = false
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
            // A click on the picture itself lets go of what's picked out on the strip.
            if dragKind == .pending, model.slice != nil, !model.isConfirmingDelete {
                clearSlice()
            }
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
        guard !text.isEmpty else {
            model.showToast(String(localized: "There's no text on this frame to copy"))
            return
        }
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        model.showToast(String(localized: "Copied text"))
    }

    /// The frame on screen as an image.
    public func currentImage() -> NSImage? {
        guard let shownBuffer else { return nil }
        let image = CIImage(cvPixelBuffer: shownBuffer)
        guard let cgImage = Self.imageContext.createCGImage(image, from: image.extent) else { return nil }
        return NSImage(cgImage: cgImage, size: .zero)
    }

    /// The frame on screen, if there is one.
    public var currentFrameID: Int64? { shownFrameID }

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
            let isStarred = (try? core.isStarred(frameID: frameID)) ?? false
            await self?.showDetails(context: context ?? nil, isStarred: isStarred, frameID: frameID)
        }
    }

    private func showDetails(context: FrameContext?, isStarred: Bool, frameID: Int64) {
        guard frameID == shownFrameID else { return }
        model.showContext(context)
        if model.isStarred != isStarred {
            model.isStarred = isStarred
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
            let stars = (try? core.stars(display: display, from: from, to: to)) ?? []
            let speech = ((try? core.transcriptSessions(from: from, to: to, limit: 500)) ?? [])
                .map { DateInterval(start: $0.start, end: max($0.end, $0.start)) }
            await self?.apply(data, stars: stars, speech: speech, origin: from, for: display)
        }
    }

    private func apply(
        _ data: TimelineData,
        stars: [StarredFrame],
        speech: [DateInterval],
        origin: Date,
        for forDisplay: UUID
    ) {
        guard forDisplay == display else { return }
        timelineOrigin = origin
        runs = data.runs
        apps = data.apps
        self.stars = stars
        self.speech = speech
        let palette = data.apps.map(color(for:))
        let images = data.apps.map(icon(for:))
        let stripRuns = data.runs.map { run in
            StripRun(
                start: Float(run.start.timeIntervalSince(origin)),
                end: Float(run.end.timeIntervalSince(origin)),
                color: palette[run.app]
            )
        }
        let icons = zip(stripRuns, data.runs).compactMap { strip, run in
            images[run.app].map { StripIcon(start: strip.start, end: strip.end, image: $0) }
        }
        stripView?.setRuns(stripRuns, icons: icons)
        applyOverlays()
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
