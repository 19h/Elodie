import AppKit
import Capture
import CoreAPI
import CoreVideo
import DesignSystem
import FeatureSearch
import FeatureTimeline
import Observation
import OverlayShell
import SwiftUI

/// Opens and closes the overlay, and connects the search panel to the timeline.
@MainActor
final class OverlayCoordinator {
    private let core: any RemindCore
    private var panel: OverlayPanel?
    private var timeline: TimelineController?
    private let search: SearchModel
    private weak var searchField: NSTextField?
    private var isSearchEditing = false
    private var highlights = HighlightModel()
    private var observers: [Any] = []

    /// The most recent captured frame, shown first so opening feels instant.
    var latestFrame: () -> CVPixelBuffer? = { nil }

    private(set) var isOpen = false

    init(core: any RemindCore) {
        self.core = core
        search = SearchModel(core: core)
        observeDismissals()
    }

    func toggle(focusSearch: Bool) {
        if isOpen {
            dismiss()
        } else {
            open(focusSearch: focusSearch)
        }
    }

    func open(at time: Date = Date(), focusSearch: Bool = false) {
        guard !isOpen else {
            if focusSearch { focusSearchField() }
            return
        }
        let displayID = activeDisplayID()
        guard let screen = screen(for: displayID), let uuid = ScreenContent.stableID(of: displayID) else { return }

        let panel = OverlayPanel(screen: screen)
        let controller = TimelineController(
            core: core,
            display: uuid,
            frame: NSRect(origin: .zero, size: screen.frame.size)
        )
        controller.onAction = { [weak self] action in self?.handle(action) }
        controller.isSearchFocused = { [weak self] in self?.isSearchEditing ?? false }
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
            onSelectHit: { [weak self] hit in self?.select(hit) },
            onOpenHit: { [weak self] hit in self?.openExternally(hit) },
            fieldCreated: { [weak self] field in self?.searchField = field },
            searchEditing: { [weak self] editing in self?.isSearchEditing = editing },
            searchCancelled: { [weak self] in self?.cancelSearch() }
        ))
        panel.contentView = controller.rootView
        self.panel = panel
        timeline = controller
        isOpen = true

        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(controller.keyView)
        controller.present(at: time, immediate: latestFrame())
        search.loadApps()
        if focusSearch { focusSearchField() }
    }

    func dismiss() {
        guard isOpen else { return }
        isOpen = false
        // Hiding comes first and is synchronous, so Esc feels immediate.
        panel?.orderOut(nil)
        timeline?.stop()
        timeline = nil
        panel = nil
        isSearchEditing = false
        search.clear()
        highlights.clear()
    }

    /// Closes the overlay when something else takes over the screen. macOS prompts,
    /// Mission Control, and app switching all need the screen back.
    private func observeDismissals() {
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.activeSpaceDidChangeNotification, NSWorkspace.screensDidSleepNotification, NSWorkspace.didActivateApplicationNotification] {
            observers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.dismiss() }
            })
        }
        let distributed = DistributedNotificationCenter.default()
        observers.append(distributed.addObserver(forName: Notification.Name("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.dismiss() }
        })
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.dismiss() }
        })
    }

    private func handle(_ action: OverlayAction) {
        switch action {
        case .dismiss:
            escape()
        case .focusSearch:
            focusSearchField()
        case .typed(let text):
            focusSearchField()
            search.text += text
        case .open:
            openCurrent()
        case .star:
            starCurrent()
        default:
            break
        }
    }

    /// Esc backs out one level at a time, and closes the overlay last.
    private func escape() {
        if let model = timeline?.model, model.isJumpToDateOpen {
            model.isJumpToDateOpen = false
        } else if !search.text.isEmpty {
            cancelSearch()
        } else if search.layout == .expanded {
            search.layout = .compact
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

    private func select(_ hit: SearchHit) {
        highlights.show(hit.rects, frameID: hit.frameID)
        search.layout = .compact
        timeline?.move(to: hit.capturedAt)
        if let key = timeline?.keyView { panel?.makeFirstResponder(key) }
    }

    private func openExternally(_ hit: SearchHit) {
        open(url: hit.url, bundleID: hit.bundleID)
    }

    private func openCurrent() {
        guard let context = timeline?.model.currentContext else { return }
        open(url: context.url, bundleID: context.bundleID)
    }

    private func open(url: String?, bundleID: String?) {
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

    private func starCurrent() {
        guard let frameID = highlights.currentFrameID else { return }
        let core = self.core
        Task.detached { try? core.setStarred(true, frameID: frameID) }
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
        NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) == displayID
        } ?? NSScreen.main
    }
}

/// Where to draw search match highlights over the frame on screen.
@MainActor
@Observable
final class HighlightModel {
    private(set) var rects: [CGRect] = []
    private(set) var currentFrameID: Int64?
    private var highlightedFrame: Int64?

    func show(_ rects: [CGRect], frameID: Int64) {
        self.rects = rects
        highlightedFrame = frameID
    }

    /// Highlights belong to one frame, and moving on clears them.
    func frameChanged(to frameID: Int64) {
        currentFrameID = frameID
        if let highlightedFrame, frameID != highlightedFrame {
            rects = []
            self.highlightedFrame = nil
        }
    }

    func clear() {
        rects = []
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
    let onSelectHit: (SearchHit) -> Void
    let onOpenHit: (SearchHit) -> Void
    let fieldCreated: (NSTextField) -> Void
    let searchEditing: (Bool) -> Void
    let searchCancelled: () -> Void

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                ForEach(Array(highlights.rects.enumerated()), id: \.offset) { index, rect in
                    MatchHighlight(number: index + 1)
                        .frame(
                            width: max(rect.width * geometry.size.width, 12),
                            height: max(rect.height * geometry.size.height, 12)
                        )
                        .position(
                            x: rect.midX * geometry.size.width,
                            y: rect.midY * geometry.size.height
                        )
                }

                TimelineChrome(
                    model: timeline.model,
                    onOpen: onOpen,
                    onJumpToNow: { timeline.move(to: Date()) },
                    overflow: {
                        OverflowMenu(core: core, onDismiss: onDismiss)
                    }
                )

                if timeline.model.isJumpToDateOpen {
                    JumpToDateView(
                        core: core,
                        current: timeline.playhead,
                        onJump: { timeline.move(to: $0) }
                    )
                    .frame(maxHeight: .infinity, alignment: .bottom)
                    .padding(.bottom, 128)
                }

                VStack {
                    SearchPanel(
                        model: search,
                        field: AnyView(SearchField(
                            text: $search.text,
                            onCancel: searchCancelled,
                            onEditingChanged: searchEditing,
                            onCreated: fieldCreated
                        )),
                        thumbnail: { hit in AnyView(HitThumbnail(core: core, hit: hit)) },
                        onSelect: onSelectHit,
                        onOpen: onOpenHit
                    )
                    .padding(.top, 72)
                    .padding(.bottom, search.layout == .expanded ? 160 : 0)
                    if search.layout == .compact { Spacer() }
                }
            }
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

struct OverflowMenu: View {
    let core: any RemindCore
    let onDismiss: () -> Void

    var body: some View {
        Menu {
            Button("Star this moment", systemImage: "star") {}
            Button("Copy image", systemImage: "doc.on.clipboard") {}
            Button("Save image…", systemImage: "square.and.arrow.down") {}
            Button("Copy link to this moment", systemImage: "link") {}
            Divider()
            Button("Forget last 5 minutes", systemImage: "clock.arrow.circlepath") {}
            Button("Exclude this app", systemImage: "eye.slash") {}
        } label: {
            Image(systemName: "ellipsis")
        }
        .menuStyle(.button)
        .buttonStyle(ChromeControlStyle())
        .menuIndicator(.hidden)
        .fixedSize()
    }
}

/// A crop of a result's frame, centred on the match.
struct HitThumbnail: View {
    let core: any RemindCore
    let hit: SearchHit
    @State private var image: CGImage?

    var body: some View {
        ZStack {
            Color.white.opacity(0.05)
            if let image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .clipped()
        .task(id: hit.frameID) {
            image = await ThumbnailLoader.crop(core: core, hit: hit)
        }
    }
}
