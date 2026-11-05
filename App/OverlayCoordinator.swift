import AppKit
import Capture
import CoreAPI
import CoreVideo
import CoreImage
import DesignSystem
import FeatureSearch
import FeatureTimeline
import FrameEngine
import Observation
import OverlayShell
import QuartzCore
import SwiftUI

/// Opens and closes the overlay, and connects the search panel to the timeline.
///
/// Each display keeps a panel ready, so opening only has to show it. Nothing is created
/// at the moment you press the shortcut.
@MainActor
final class OverlayCoordinator {
    /// A display's panel and everything in it.
    private final class Prepared {
        let display: CGDirectDisplayID
        let uuid: UUID
        let panel: OverlayPanel
        let timeline: TimelineController
        weak var field: NSTextField?

        init(display: CGDirectDisplayID, uuid: UUID, panel: OverlayPanel, timeline: TimelineController) {
            self.display = display
            self.uuid = uuid
            self.panel = panel
            self.timeline = timeline
        }
    }

    private let core: any RemindCore
    private var prepared: [CGDirectDisplayID: Prepared] = [:]
    private var active: Prepared?
    private let search: SearchModel
    private var isSearchEditing = false
    private var highlights = HighlightModel()
    private var observers: [Any] = []

    private var panel: OverlayPanel? { active?.panel }
    private var timeline: TimelineController? { active?.timeline }
    private var searchField: NSTextField? { active?.field }
    private var currentDisplay: UUID? { active?.uuid }

    /// Leaves an app out of recording from now on.
    var excludeApp: (String) -> Void = { _ in }

    /// The most recent captured frame on a display, shown first so opening feels instant.
    var latestFrame: (CGDirectDisplayID) -> CVPixelBuffer? = { _ in nil }

    /// Tells whoever is routing scroll events.
    var onOpenChange: (Bool) -> Void = { _ in }
    /// Opens what was said at a moment.
    var onOpenTranscript: (Date) -> Void = { _ in }
    var settings: () -> Void = {}
    var isCapturing: () -> Bool = { true }
    var isListening: () -> Bool = { false }
    var setCapturing: (Bool) -> Void = { _ in }
    var toggleListening: () -> Void = {}
    /// Called before a stretch is deleted, so what's in progress can't bring it back.
    var prepareToDelete: (DateInterval) -> Void = { _ in }
    /// Tells whoever else is showing recordings that some are gone.
    var onRecordingsDeleted: () -> Void = {}
    /// Why search might be missing things right now.
    var searchNote: () -> String? = { nil } {
        didSet { search.note = searchNote }
    }

    private(set) var isOpen = false {
        didSet { onOpenChange(isOpen) }
    }
    private var openedForSearch = false

    init(core: any RemindCore) {
        self.core = core
        search = SearchModel(core: core)
        observeDismissals()
        // After launch has finished, since this makes a window per display.
        DispatchQueue.main.async { [weak self] in self?.prepareDisplays() }
    }

    /// Readies a panel for each display. Displays come and go, so this runs again whenever
    /// they change.
    private func prepareDisplays() {
        var ready: [CGDirectDisplayID: Prepared] = [:]
        for screen in NSScreen.screens {
            guard let display = Self.displayID(of: screen), let uuid = ScreenContent.stableID(of: display) else { continue }
            ready[display] = makeOverlay(display: display, uuid: uuid, screen: screen)
        }
        prepared = ready
    }

    private func makeOverlay(display: CGDirectDisplayID, uuid: UUID, screen: NSScreen) -> Prepared {
        let panel = OverlayPanel(screen: screen)
        #if DEBUG
        // Normally nothing can capture this, including its own process. A throwaway test run
        // has to be able to photograph itself, and whoever's at the Mac mustn't lose their
        // pointer to it, or steer it by accident.
        if AppEnvironment.sandbox != nil {
            panel.sharingType = .readOnly
            panel.ignoresMouseEvents = true
        }
        #endif
        let controller = TimelineController(
            core: core,
            display: uuid,
            frame: NSRect(origin: .zero, size: screen.frame.size)
        )
        let overlay = Prepared(display: display, uuid: uuid, panel: panel, timeline: controller)
        controller.onAction = { [weak self] action in self?.handle(action) }
        controller.isSearchFocused = { [weak self] in self?.isSearchEditing ?? false }
        controller.displayName = { Self.name(of: $0) }
        controller.onFrameShown = { [weak self] frameID, _ in
            self?.highlights.frameChanged(to: frameID)
        }
        controller.install(chrome: OverlayContent(
            core: core,
            timeline: controller,
            search: search,
            highlights: highlights,
            onOpen: { [weak self] in self?.openCurrent() },
            onDismiss: { [weak self] in self?.dismiss() },
            actions: OverflowActions(
                isStarred: { [weak controller] in controller?.model.isStarred ?? false },
                star: { [weak self] in self?.starCurrent() },
                copyText: { [weak self] in self?.timeline?.copySelection() },
                copyImage: { [weak self] in self?.copyImage() },
                saveImage: { [weak self] in self?.saveImage() },
                copyLink: { [weak self] in self?.copyLink() },
                exportClip: { [weak self] in self?.exportClip() },
                forget: { [weak self] in self?.forgetRecent() },
                exclude: { [weak self] in self?.excludeCurrentApp() },
                isCapturing: { [weak self] in self?.isCapturing() ?? true },
                isListening: { [weak self] in self?.isListening() ?? false },
                setCapturing: { [weak self] in self?.setCapturing($0) },
                toggleListening: { [weak self] in self?.toggleListening() },
                settings: { [weak self] in
                    self?.dismiss()
                    self?.settings()
                }
            ),
            sliceActions: SliceActions(
                star: { [weak self] slice in self?.starStart(of: slice) },
                export: { [weak self] slice in self?.export(slice) },
                exclude: { [weak self] bundleID in self?.excludeSliceApp(bundleID) },
                delete: { [weak self] slice in try await self?.delete(slice) }
            ),
            onSelectHit: { [weak self] hit, cardFrame in self?.select(hit, from: cardFrame) },
            onOpenHit: { [weak self] hit in self?.openExternally(hit) },
            fieldCreated: { [weak overlay] field in overlay?.field = field },
            searchEditing: { [weak self] editing in self?.isSearchEditing = editing },
            searchCancelled: { [weak self] in self?.escape() },
            searchSubmitted: { [weak self] in self?.chooseResult() }
        ))
        controller.onUserMoved = { [weak self] in self?.highlights.clear() }
        panel.contentView = controller.rootView
        return overlay
    }

    func toggle(focusSearch: Bool) {
        if isOpen {
            dismiss()
        } else {
            open(focusSearch: focusSearch)
        }
    }

    func open(at time: Date = Date(), display: UUID? = nil, focusSearch: Bool = false) {
        guard !isOpen else {
            if let display { timeline?.showDisplay(display) }
            timeline?.move(to: time)
            if focusSearch {
                timeline?.model.isSearchVisible = true
                focusSearchField()
            }
            return
        }
        let displayOverride = display
        let display = activeDisplayID()
        guard let overlay = prepared[display] ?? makeMissingOverlay(for: display) else { return }
        active = overlay
        isOpen = true
        openedForSearch = focusSearch
        overlay.timeline.showDisplay(displayOverride ?? overlay.uuid)
        overlay.timeline.model.isSearchVisible = focusSearch

        // The picture goes in before the window comes up, so the first thing to reach the
        // screen is the frame, in the right place, with no black refresh in between. That's
        // what makes it look like your screen stopping, instead of a window opening.
        let immediate = displayOverride == nil ? latestFrame(display) : nil
        overlay.timeline.present(at: time, immediate: immediate) { [weak self, weak overlay] in
            guard let self, let overlay, self.active === overlay else { return }
            CATransaction.flush()
            #if DEBUG
            if AppEnvironment.sandbox != nil {
                overlay.panel.orderFrontRegardless()
                return
            }
            #endif
            overlay.panel.makeKeyAndOrderFront(nil)
            overlay.panel.makeFirstResponder(overlay.timeline.keyView)
            if focusSearch { self.focusSearchField() }
        }
        search.loadApps()
    }

    /// A scroll taken over from whatever app was underneath. The swipe that opens the
    /// timeline is the same one that moves through it, so it all feels like one motion.
    func handleScroll(_ event: NSEvent) {
        if !isOpen {
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard flags.contains(.command), flags.contains(.shift),
                  event.momentumPhase.isEmpty,
                  event.scrollingDeltaY > 0
            else { return }
            open()
        }
        timeline?.keyView.scrollWheel(with: event)
    }

    #if DEBUG
    var debugDismissReason = "none"
    var debugDisplay: UUID? { timeline?.display }
    var debugHits: String {
        search.hits.prefix(6).map { "frame \($0.frameID) at \($0.capturedAt.timeIntervalSince1970): \($0.snippet)" }.joined(separator: "\n")
    }

    /// Runs the search field's job without the keyboard, for a sandboxed run driven from outside.
    func debugSearch(_ text: String) {
        timeline?.model.isSearchVisible = true
        search.text = text
    }

    func debugChooseResult() { chooseResult() }
    func debugClickPlayhead() {
        guard let width = panel?.frame.width else { return }
        let middle = Double(width) / 2
        timeline?.simulateStrip(.down(middle, clicks: 1))
        timeline?.simulateStrip(.up(middle))
    }
    func debugFilterStarred() {
        timeline?.model.isSearchVisible = true
        search.starredOnly = true
    }
    func debugExportSelection(to url: URL) async throws {
        guard let slice = timeline?.model.slice, let display = timeline?.display else { return }
        try await MP4Exporter.export(core: core, display: display, from: slice.start, to: slice.end, to: url)
    }
    func debugEscape() { escape() }
    func debugMove(to time: Date) { timeline?.move(to: time) }
    func debugStrip(_ event: StripInteractionView.Event) { timeline?.simulateStrip(event) }
    func debugStar() { starCurrent() }
    func debugDeleteSelection() async throws {
        guard let slice = timeline?.model.slice else { return }
        try await delete(slice)
        timeline?.clearSlice()
    }
    var debugPanelWindow: CGWindowID? { (panel?.windowNumber).map { CGWindowID($0) } }
    var debugState: [String: String] {
        guard let timeline else { return ["open": "false", "dismissedBy": debugDismissReason] }
        return [
            "open": "true",
            "playhead": "\(timeline.playhead.timeIntervalSince1970)",
            "label": timeline.model.timeLabel,
            "frame": timeline.currentFrameID.map(String.init) ?? "none",
            "isEmpty": "\(timeline.model.isEmpty)",
            "isStarred": "\(timeline.model.isStarred)",
            "app": timeline.model.currentContext?.bundleID ?? "none",
            "window": timeline.model.currentContext?.window ?? "none",
            "toast": timeline.model.toast ?? "none",
            "slice": timeline.model.slice.map { "\($0.start.timeIntervalSince1970)...\($0.end.timeIntervalSince1970)" } ?? "none",
            "hits": "\(search.hits.count)",
            "searching": "\(search.isSearching)",
            "firstHit": search.hits.first.map { "\($0.frameID) \($0.snippet) rects=\($0.rects.count) display=\($0.display?.uuidString ?? "none")" } ?? "none",
            "highlightRects": "\(highlights.rects.count)",
            "displays": "\(timeline.model.recordedDisplays.count)",
        ]
    }

    /// Where the timeline is, for checks that drive it with real events.
    var debugPlayhead: Date? { timeline?.playhead }
    var debugIsPanelVisible: Bool { panel?.isVisible ?? false }
    var debugIsReady: Bool { !prepared.isEmpty }
    #endif

    /// A display that appeared without the usual notice.
    private func makeMissingOverlay(for display: CGDirectDisplayID) -> Prepared? {
        guard let screen = screen(for: display), let uuid = ScreenContent.stableID(of: display) else { return nil }
        let overlay = makeOverlay(display: display, uuid: uuid, screen: screen)
        prepared[display] = overlay
        return overlay
    }

    func dismiss() {
        guard isOpen else { return }
        isOpen = false
        // Hiding comes first and is synchronous, so Esc feels immediate.
        panel?.orderOut(nil)
        timeline?.stop()
        active = nil
        isSearchEditing = false
        search.clear()
        highlights.clear()
    }

    /// Closes the overlay when something else takes over the screen. macOS prompts,
    /// Mission Control, and app switching all need the screen back.
    private func observeDismissals() {
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.activeSpaceDidChangeNotification, NSWorkspace.screensDidSleepNotification, NSWorkspace.didActivateApplicationNotification] {
            observers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                #if DEBUG
                let app = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier ?? ""
                let reason = "\(name.rawValue) \(app)"
                #endif
                MainActor.assumeIsolated {
                    #if DEBUG
                    if self?.isOpen == true { self?.debugDismissReason = reason }
                    #endif
                    self?.dismiss()
                }
            })
        }
        let distributed = DistributedNotificationCenter.default()
        observers.append(distributed.addObserver(forName: Notification.Name("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.dismiss() }
        })
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                #if DEBUG
                if self?.isOpen == true { self?.debugDismissReason = "screen parameters changed" }
                #endif
                self?.dismiss()
                self?.prepareDisplays()
            }
        })
    }

    private func handle(_ action: OverlayAction) {
        switch action {
        case .dismiss:
            escape()
        case .focusSearch:
            timeline?.model.isSearchVisible = true
            focusSearchField()
        case .typed(let text):
            timeline?.model.isSearchVisible = true
            focusSearchField()
            search.text += text
        case .open:
            openCurrent()
        case .star:
            starCurrent()
        case .copyImage:
            copyImage()
        default:
            break
        }
    }

    /// Esc backs out one level at a time, and closes the overlay last.
    private func escape() {
        if let model = timeline?.model, model.isJumpToDateOpen {
            model.isJumpToDateOpen = false
        } else if let model = timeline?.model, model.isConfirmingForget {
            model.isConfirmingForget = false
        } else if let model = timeline?.model, model.isConfirmingDelete {
            model.isConfirmingDelete = false
        } else if timeline?.model.slice != nil {
            timeline?.clearSlice()
        } else if timeline?.model.isZoomOpen == true {
            timeline?.model.isZoomOpen = false
        } else if search.isAppsOpen {
            search.isAppsOpen = false
        } else if !search.text.isEmpty, search.layout == .compact {
            // Back to the results after looking at one.
            search.layout = .expanded
            highlights.clear()
        } else if !search.text.isEmpty {
            cancelSearch()
        } else if search.isBrowsing {
            search.clear()
            timeline?.model.isSearchVisible = openedForSearch
            if let key = timeline?.keyView { panel?.makeFirstResponder(key) }
        } else if search.layout == .expanded {
            search.layout = .compact
        } else if let model = timeline?.model, model.isSearchVisible, !openedForSearch {
            // It wasn't showing when this opened, so the frame goes back to being clear.
            model.isSearchVisible = false
            if let key = timeline?.keyView { panel?.makeFirstResponder(key) }
        } else {
            dismiss()
        }
    }

    private func cancelSearch() {
        if search.text.isEmpty {
            search.layout = .compact
            if let key = timeline?.keyView { panel?.makeFirstResponder(key) }
        } else {
            search.text = ""
        }
        highlights.clear()
    }

    private func focusSearchField() {
        if let searchField {
            panel?.makeFirstResponder(searchField)
            // Keep what's been typed, and put the caret at the end.
            searchField.currentEditor()?.selectedRange = NSRange(location: searchField.stringValue.utf16.count, length: 0)
        }
    }

    private func chooseResult() {
        guard let hit = search.chosenHit else { return }
        select(hit, from: search.cardFrames[hit.id] ?? .zero)
    }

    private func select(_ hit: SearchHit, from cardFrame: CGRect) {
        // What was said has no frame to show, but it does have a transcript to read.
        if hit.isTranscript {
            let time = hit.capturedAt
            dismiss()
            onOpenTranscript(time)
            return
        }
        // Recording follows the pointer, so this can be from another display.
        if let display = hit.display {
            timeline?.showDisplay(display)
        }
        highlights.show(hit.rects, frameID: hit.frameID)
        search.layout = .compact
        timeline?.move(to: hit.capturedAt)
        if cardFrame != .zero {
            timeline?.flyIn(from: cardFrame)
        }
        if let key = timeline?.keyView { panel?.makeFirstResponder(key) }
    }

    private func openExternally(_ hit: SearchHit) {
        if hit.isTranscript {
            select(hit, from: .zero)
            return
        }
        open(url: hit.url, bundleID: hit.bundleID)
    }

    private func openCurrent() {
        guard let context = timeline?.model.currentContext else { return }
        open(url: context.url, bundleID: context.bundleID)
    }

    private func open(url: String?, bundleID: String?) {
        // Check before closing, so a moment that can't be reopened doesn't just vanish.
        let canOpenApp = bundleID.flatMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) } != nil
        guard url.flatMap(Self.webURL(from:)) != nil || canOpenApp else {
            timeline?.model.showToast(String(localized: "That app isn't on this Mac any more"))
            return
        }
        dismiss()
        if let url, let target = Self.webURL(from: url) {
            if let bundleID, let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
                NSWorkspace.shared.open([target], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
            } else {
                NSWorkspace.shared.open(target)
            }
        } else if let bundleID, let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            NSWorkspace.shared.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration())
        }
    }

    /// Address bars often leave off the scheme.
    private static func webURL(from text: String) -> URL? {
        if let url = URL(string: text), url.scheme == "http" || url.scheme == "https" {
            return url
        }
        guard !text.contains(" "), text.contains(".") else { return nil }
        return URL(string: "https://\(text)")
    }

    /// Stars the moment on screen, or takes the star away if it has one.
    private func starCurrent() {
        guard let timeline, let frameID = timeline.currentFrameID else { return }
        let starring = !timeline.model.isStarred
        let core = self.core
        Task { [weak timeline] in
            do {
                try await Task.detached(priority: .userInitiated) {
                    try core.setStarred(starring, frameID: frameID)
                }.value
                timeline?.model.isStarred = starring
                timeline?.model.showToast(starring ? String(localized: "Starred") : String(localized: "Star removed"))
                timeline?.reloadMarks()
            } catch {
                timeline?.model.showToast(String(localized: "That couldn't be starred"))
            }
        }
    }

    /// Stars the first frame of a stretch, so it can be found again in the Starred filter.
    private func starStart(of slice: DateInterval) {
        guard let timeline else { return }
        let core = self.core
        let display = timeline.display
        Task { [weak timeline] in
            let starred: Bool = await Task.detached(priority: .userInitiated) {
                guard let frame = try? core.lookup(display: display, at: slice.start.addingTimeInterval(1)) else { return false }
                return (try? core.setStarred(true, frameID: frame.id)) != nil
            }.value
            timeline?.model.showToast(starred ? String(localized: "Starred") : String(localized: "That couldn't be starred"))
            timeline?.reloadMarks()
        }
    }

    private func delete(_ slice: DateInterval) async throws {
        prepareToDelete(slice)
        let core = self.core
        try await Task.detached(priority: .userInitiated) {
            _ = try core.deleteRange(from: slice.start, to: slice.end)
        }.value
        recordingsChanged()
        onRecordingsDeleted()
    }

    /// Recordings were deleted somewhere, so nothing on show may still exist.
    func recordingsChanged() {
        timeline?.recordingsChanged()
        for overlay in prepared.values where overlay !== active {
            overlay.timeline.forgetFrames()
        }
        if !search.text.isEmpty || search.isBrowsing {
            search.refresh()
        }
    }

    private func excludeSliceApp(_ bundleID: String) {
        excludeApp(bundleID)
        let name = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)?
            .deletingPathExtension().lastPathComponent ?? bundleID
        timeline?.model.showToast(String(localized: "\(name) won't be recorded from now on"))
    }

    private func currentImage() -> NSImage? {
        timeline?.currentImage()
    }

    private func copyImage() {
        guard let image = currentImage() else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([image])
        timeline?.model.showToast(String(localized: "Copied image"))
    }

    private func saveImage() {
        guard let image = currentImage() else { return }
        dismiss()
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "Remind \(Self.fileDate()).png"
        NSApp.activate()
        guard panel.runModal() == .OK, let url = panel.url,
              let data = image.tiffRepresentation,
              let png = NSBitmapImageRep(data: data)?.representation(using: .png, properties: [:])
        else { return }
        do {
            try png.write(to: url)
        } catch {
            showResult(String(localized: "The image couldn't be saved"), detail: error.localizedDescription)
        }
    }

    private func showResult(_ title: String, detail: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        NSApp.activate()
        alert.runModal()
    }

    private func copyLink() {
        guard let time = timeline?.playhead else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(DeepLink.url(for: time).absoluteString, forType: .string)
        timeline?.model.showToast(String(localized: "Copied link"))
    }

    /// Exports the 5 minutes around the playhead as a video file.
    private func exportClip() {
        guard let time = timeline?.playhead else { return }
        export(DateInterval(start: time.addingTimeInterval(-150), end: min(time.addingTimeInterval(150), Date())))
    }

    /// Exports a stretch as an ordinary video, and says how it went.
    private func export(_ slice: DateInterval) {
        guard let display = timeline?.display else { return }
        dismiss()
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.mpeg4Movie]
        panel.nameFieldStringValue = "Remind \(Self.fileDate()).mp4"
        panel.message = String(localized: "This saves an unencrypted copy of this stretch of your screen.")
        NSApp.activate()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let core = self.core
        Task { [weak self] in
            do {
                let summary = try await Task.detached(priority: .userInitiated) {
                    try await MP4Exporter.export(
                        core: core,
                        display: display,
                        from: slice.start,
                        to: slice.end,
                        to: url
                    )
                }.value
                NSWorkspace.shared.activateFileViewerSelecting([url])
                if let stopped = summary.stoppedEarlyAt {
                    self?.showResult(
                        String(localized: "The video stops early"),
                        detail: String(localized: "The display changed resolution at \(stopped.formatted(date: .omitted, time: .shortened)), and one video can't hold both. Export from that moment on to get the rest.")
                    )
                }
            } catch ExportError.nothingRecorded {
                self?.showResult(
                    String(localized: "There's nothing to export"),
                    detail: String(localized: "Nothing was recorded on this display in that stretch.")
                )
            } catch {
                self?.showResult(
                    String(localized: "The video couldn't be saved"),
                    detail: error.localizedDescription
                )
            }
        }
    }

    /// Permanently deletes the last 5 minutes. Recording carries on from now.
    private func forgetRecent() {
        let now = Date()
        let slice = DateInterval(start: now.addingTimeInterval(-5 * 60), end: now)
        Task { [weak self] in
            do {
                try await self?.delete(slice)
                self?.timeline?.model.showToast(String(localized: "Forgot the last 5 minutes"))
            } catch {
                self?.timeline?.model.showToast(String(localized: "The last 5 minutes couldn't be deleted"))
            }
        }
    }

    private func excludeCurrentApp() {
        guard let bundleID = timeline?.model.currentContext?.bundleID else { return }
        excludeSliceApp(bundleID)
    }

    private static func fileDate() -> String {
        Date().formatted(.iso8601.year().month().day().dateTimeSeparator(.space).time(includingFractionalSeconds: false))
            .replacingOccurrences(of: ":", with: "-")
    }

    /// A display's own name if it's still connected, or its size if it isn't.
    private static func name(of display: RecordedDisplay) -> String {
        let connected = NSScreen.screens.first { screen in
            Self.displayID(of: screen).flatMap(ScreenContent.stableID(of:)) == display.id
        }
        return connected?.localizedName ?? String(localized: "Display, \(display.width) × \(display.height)")
    }

    private static func displayID(of screen: NSScreen) -> CGDirectDisplayID? {
        screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }

    private func activeDisplayID() -> CGDirectDisplayID {
        let location = CGEvent(source: nil)?.location ?? .zero
        var display = CGDirectDisplayID()
        var count: UInt32 = 0
        if CGGetDisplaysWithPoint(location, 1, &display, &count) == .success, count > 0 {
            return display
        }
        return CGMainDisplayID()
    }

    private func screen(for displayID: CGDirectDisplayID) -> NSScreen? {
        NSScreen.screens.first { Self.displayID(of: $0) == displayID } ?? NSScreen.main
    }
}

/// Where to draw search match highlights over the frame on screen.
@MainActor
@Observable
final class HighlightModel {
    private var matches: [CGRect] = []
    private(set) var currentFrameID: Int64?
    private var highlightedFrame: Int64?

    /// Highlights belong to one frame, so they only show on that frame.
    var rects: [CGRect] {
        currentFrameID == highlightedFrame ? matches : []
    }

    func show(_ rects: [CGRect], frameID: Int64) {
        matches = rects
        highlightedFrame = frameID
    }

    /// Getting to a result can show a nearby picture first, so this has to wait for the right
    /// one instead of giving up at the first frame that isn't it.
    func frameChanged(to frameID: Int64) {
        currentFrameID = frameID
    }

    /// Moving on by hand is what ends them.
    func clear() {
        matches = []
        highlightedFrame = nil
    }
}

/// Everything drawn over the frame.
struct OverlayContent: View {
    let core: any RemindCore
    let timeline: TimelineController
    @Bindable var search: SearchModel
    let highlights: HighlightModel
    let onOpen: () -> Void
    let onDismiss: () -> Void
    var actions = OverflowActions()
    var sliceActions = SliceActions()
    let onSelectHit: (SearchHit, CGRect) -> Void
    let onOpenHit: (SearchHit) -> Void
    let fieldCreated: (NSTextField) -> Void
    let searchEditing: (Bool) -> Void
    let searchCancelled: () -> Void
    var coachMarks = CoachMarkProgress()
    var searchSubmitted: () -> Void = {}

    private var isSearchShowing: Bool {
        let model = timeline.model
        return model.isSearchVisible && model.isChromeVisible && !model.isJumpToDateOpen
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                let picture = timeline.model.pictureRect ?? CGRect(origin: .zero, size: geometry.size)
                ForEach(Array(highlights.rects.enumerated()), id: \.offset) { index, rect in
                    MatchHighlight(number: index + 1)
                        .frame(
                            width: max(rect.width * picture.width, 12),
                            height: max(rect.height * picture.height, 12)
                        )
                        .position(
                            x: picture.minX + rect.midX * picture.width,
                            y: picture.minY + rect.midY * picture.height
                        )
                }

                TimelineChrome(
                    model: timeline.model,
                    onOpen: onOpen,
                    onJumpToNow: {
                        timeline.onUserMoved?()
                        timeline.move(to: Date())
                    },
                    onZoom: { timeline.setZoom(fraction: $0) },
                    onZoomToSlice: { timeline.zoomToSlice() },
                    onClearSlice: { timeline.clearSlice() },
                    onChooseDisplay: { timeline.chooseDisplay($0) },
                    sliceActions: sliceActions,
                    overflow: {
                        OverflowMenu(model: timeline.model, actions: actions)
                    }
                )
                .offset(y: timeline.model.isChromeVisible ? 0 : 12)
                .opacity(timeline.model.isChromeVisible ? 1 : 0)

                if timeline.model.isJumpToDateOpen {
                    VStack {
                        Spacer(minLength: 0)
                        JumpToDateView(
                            core: core,
                            current: timeline.playhead,
                            onJump: {
                                timeline.onUserMoved?()
                                timeline.move(to: $0)
                            },
                            onClose: { timeline.model.isJumpToDateOpen = false }
                        )
                        .padding(.bottom, 80 + 36 + 2)
                        // Otherwise the keyboard stays with a field that's gone.
                        .onDisappear { timeline.restoreKeyFocus() }
                    }
                }

                VStack {
                    SearchPanel(
                        model: search,
                        field: AnyView(SearchField(
                            text: $search.text,
                            onCancel: searchCancelled,
                            onEditingChanged: searchEditing,
                            onCreated: fieldCreated,
                            onMove: { search.move($0) },
                            onSubmit: searchSubmitted
                        )),
                        thumbnail: { hit in AnyView(HitThumbnail(core: core, hit: hit)) },
                        onSelect: onSelectHit,
                        onOpen: onOpenHit
                    )
                    .padding(.top, 72)
                    .padding(.bottom, search.layout == .expanded ? 136 : 0)
                    .padding(.horizontal, 80)
                    if search.layout == .compact { Spacer() }
                }
                // The field stays alive underneath, so typing still reaches it.
                .opacity(isSearchShowing ? 1 : 0)
                .allowsHitTesting(isSearchShowing)

                // Results and a selection need the room, and the hints will wait.
                if (search.layout == .compact || !isSearchShowing), timeline.model.slice == nil {
                    CoachMarkLayer(progress: coachMarks)
                }
            }
        }
    }
}

/// How far someone has got through the first-run hints.
@MainActor
@Observable
final class CoachMarkProgress {
    private let defaults: UserDefaults
    private(set) var step: Int

    static let stepCount = 3

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        step = defaults.integer(forKey: "coachMarkStep")
    }

    func advance() {
        step += 1
        defaults.set(step, forKey: "coachMarkStep")
    }
}

/// Three hints over your own recordings, the first few times the timeline opens. Each one
/// waits for you, so they never get in the way of something you came here to do.
struct CoachMarkLayer: View {
    let progress: CoachMarkProgress

    private struct Hint {
        let text: LocalizedStringKey
        let alignment: Alignment
        let edge: Edge.Set
        let distance: CGFloat
    }

    private let hints = [
        Hint(text: "Scroll to move back through time.", alignment: .bottom, edge: .bottom, distance: 140),
        Hint(text: "Start typing to search everything you've seen.", alignment: .top, edge: .top, distance: 200),
        Hint(text: "Press Esc to go back to what you were doing.", alignment: .center, edge: .top, distance: 0),
    ]

    var body: some View {
        if progress.step < CoachMarkProgress.stepCount {
            let hint = hints[progress.step]
            HStack(spacing: 14) {
                Text(hint.text)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.white)
                Button(progress.step == CoachMarkProgress.stepCount - 1 ? "Got it" : "Next") {
                    progress.advance()
                }
                .buttonStyle(PrimaryActionStyle(font: .system(size: 13, weight: .semibold), horizontalPadding: 12, verticalPadding: 4))
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 14)
            .background {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(white: 0.12).opacity(0.96))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Palette.verdigris.opacity(0.6))
            }
            .shadow(color: .black.opacity(0.4), radius: 16, y: 6)
            .padding(hint.edge, hint.distance)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: hint.alignment)
            .id(progress.step)
        }
    }
}

/// Marks a search match on the frame, with a number when there's more than one.
struct MatchHighlight: View {
    let number: Int

    var body: some View {
        RoundedRectangle(cornerRadius: 4)
            .strokeBorder(Palette.marker, lineWidth: 2)
            .background(Palette.marker.opacity(0.18), in: RoundedRectangle(cornerRadius: 4))
            .shadow(color: .black.opacity(0.5), radius: 2)
            .overlay(alignment: .topLeading) {
                Text("\(number)")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.black)
                    .frame(width: 18, height: 18)
                    .background(Palette.marker, in: Circle())
                    .offset(x: -9, y: -9)
            }
            .allowsHitTesting(false)
    }
}

/// What the overflow menu can do.
struct OverflowActions {
    var isStarred: () -> Bool = { false }
    var star: () -> Void = {}
    var copyText: () -> Void = {}
    var copyImage: () -> Void = {}
    var saveImage: () -> Void = {}
    var copyLink: () -> Void = {}
    var exportClip: () -> Void = {}
    var forget: () -> Void = {}
    var exclude: () -> Void = {}
    var isCapturing: () -> Bool = { true }
    var isListening: () -> Bool = { false }
    var setCapturing: (Bool) -> Void = { _ in }
    var toggleListening: () -> Void = {}
    var settings: () -> Void = {}
}

struct OverflowMenu: View {
    @Bindable var model: TimelineModel
    let actions: OverflowActions

    var body: some View {
        Button(action: showMenu) {
            Image(systemName: "ellipsis")
        }
        .buttonStyle(ChromeIconStyle())
        .help("More")
        .accessibilityLabel("More actions")
        // Deleting can't be undone, so this asks in place. A separate alert window
        // wouldn't work over a panel that never activates.
        .overlay(alignment: .bottomTrailing) {
            if model.isConfirmingForget {
                ReadingSurface(cornerRadius: 14) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Forget the last 5 minutes?")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.white)
                        Text("This permanently deletes those recordings and their text.")
                            .font(.system(size: 13))
                            .foregroundStyle(.white.opacity(0.7))
                            .fixedSize(horizontal: false, vertical: true)
                        HStack {
                            Button("Cancel") { model.isConfirmingForget = false }
                            Button("Forget", role: .destructive) {
                                model.isConfirmingForget = false
                                actions.forget()
                            }
                            .buttonStyle(DestructiveActionStyle())
                        }
                    }
                    .padding(14)
                }
                .frame(width: 280)
                .fixedSize(horizontal: true, vertical: true)
                .offset(y: -44)
            }
        }
    }

    /// A plain menu, which shows above the overlay and works without activating the app.
    private func showMenu() {
        let menu = NSMenu()
        func add(
            _ title: String,
            _ symbol: String,
            key: String = "",
            modifiers: NSEvent.ModifierFlags = [.command, .shift],
            _ action: @escaping () -> Void
        ) {
            let item = ActionMenuItem(title: title, action: action)
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            item.keyEquivalent = key
            item.keyEquivalentModifierMask = key.isEmpty ? [] : modifiers
            if #available(macOS 27, *) {
                item.preferredImageVisibility = .visible
            }
            menu.addItem(item)
        }
        if actions.isStarred() {
            add(String(localized: "Remove star"), "star.slash", key: "s", actions.star)
        } else {
            add(String(localized: "Star moment"), "star", key: "s", actions.star)
        }
        add(String(localized: "Save image…"), "square.and.arrow.down", actions.saveImage)
        add(String(localized: "Copy image"), "doc.on.doc", key: "c", actions.copyImage)
        add(String(localized: "Copy text"), "text.viewfinder", key: "c", modifiers: .command, actions.copyText)
        add(String(localized: "Copy link to this moment"), "link", actions.copyLink)
        add(String(localized: "Export 5 minutes as video…"), "film", actions.exportClip)
        menu.addItem(.separator())
        let screen = NSMenuItem()
        screen.view = SwitchRowView(
            title: String(localized: "Screen capture"),
            symbol: "rectangle.dashed.badge.record",
            isOn: actions.isCapturing(),
            onChange: actions.setCapturing
        )
        menu.addItem(screen)
        let audio = NSMenuItem()
        audio.view = SwitchRowView(
            title: String(localized: "Audio capture"),
            symbol: "waveform",
            isOn: actions.isListening(),
            onChange: { _ in actions.toggleListening() }
        )
        menu.addItem(audio)
        menu.addItem(.separator())
        add(String(localized: "Exclude this app from recording"), "eye.slash", actions.exclude)
        add(String(localized: "Forget the last 5 minutes…"), "clock.arrow.circlepath") { [model] in model.isConfirmingForget = true }
        add(String(localized: "Settings…"), "gearshape", actions.settings)
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }
}

/// A menu item that runs a closure.
final class ActionMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, action handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("Not used") }

    @objc private func fire() { handler() }
}

/// A crop of a result's frame, centred on the match.
struct HitThumbnail: View {
    let core: any RemindCore
    let hit: SearchHit
    @State private var image: CGImage?
    @State private var didFail = false

    var body: some View {
        ZStack {
            Color.white.opacity(0.05)
            if hit.isTranscript {
                // Something said has no frame to show, so the words stand in.
                VStack(alignment: .leading, spacing: 8) {
                    Image(systemName: "waveform")
                        .foregroundStyle(Palette.verdigris)
                    Text(hit.snippet)
                        .font(.system(size: 14))
                        .foregroundStyle(.white.opacity(0.9))
                        .lineLimit(5)
                    Spacer(minLength: 0)
                }
                .padding(14)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else if let image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else if didFail {
                Image(systemName: "photo")
                    .font(.system(size: 22))
                    .foregroundStyle(.white.opacity(0.3))
                    .accessibilityLabel("This picture can't be shown")
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .clipped()
        .task(id: hit.frameID) {
            guard !hit.isTranscript else { return }
            didFail = false
            image = await ThumbnailLoader.crop(core: core, hit: hit)
            didFail = image == nil
        }
    }
}
