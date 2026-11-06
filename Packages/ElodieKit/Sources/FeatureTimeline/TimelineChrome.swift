import AppKit
import CoreAPI
import DesignSystem
import SwiftUI

/// Where things sit at the bottom of the timeline, in points from the bottom edge.
enum TimelineMetrics {
    /// The strip is drawn in Metal, so it's laid out by the controller.
    static let stripBottom: CGFloat = 26
    static let stripHeight: CGFloat = 40
    static let stripCenter: CGFloat = stripBottom + stripHeight / 2
    static let playheadHeight: CGFloat = 74
    static let controlsBottom: CGFloat = playheadHeight + 6
}

/// What can be done to a stretch picked out on the strip.
public struct SliceActions {
    public var star: (DateInterval) -> Void
    public var export: (DateInterval) -> Void
    public var exclude: (String) -> Void
    /// Deletes the stretch. Throws if it couldn't.
    public var delete: (DateInterval) async throws -> Void

    public init(
        star: @escaping (DateInterval) -> Void = { _ in },
        export: @escaping (DateInterval) -> Void = { _ in },
        exclude: @escaping (String) -> Void = { _ in },
        delete: @escaping (DateInterval) async throws -> Void = { _ in }
    ) {
        self.star = star
        self.export = export
        self.exclude = exclude
        self.delete = delete
    }
}

/// The controls over a frame: the time pill, Open, and overflow. The strip and playhead
/// are drawn above these, outside SwiftUI, since they move on every scroll event.
public struct TimelineChrome: View {
    @Bindable private var model: TimelineModel
    private let onOpen: () -> Void
    private let onJumpToNow: () -> Void
    private let onZoom: (Double) -> Void
    private let onZoomToSlice: () -> Void
    private let onClearSlice: () -> Void
    private let onChooseDisplay: (UUID) -> Void
    private let sliceActions: SliceActions
    private let overflow: AnyView

    public init(
        model: TimelineModel,
        onOpen: @escaping () -> Void,
        onJumpToNow: @escaping () -> Void,
        onZoom: @escaping (Double) -> Void = { _ in },
        onZoomToSlice: @escaping () -> Void = {},
        onClearSlice: @escaping () -> Void = {},
        onChooseDisplay: @escaping (UUID) -> Void = { _ in },
        sliceActions: SliceActions = SliceActions(),
        @ViewBuilder overflow: () -> some View
    ) {
        self.model = model
        self.onOpen = onOpen
        self.onJumpToNow = onJumpToNow
        self.onZoom = onZoom
        self.onZoomToSlice = onZoomToSlice
        self.onClearSlice = onClearSlice
        self.onChooseDisplay = onChooseDisplay
        self.sliceActions = sliceActions
        self.overflow = AnyView(overflow())
    }

    public var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .bottom) {
                ChromeScrim()

                GlassEffectContainer {
                    timePill
                }
                .padding(.bottom, TimelineMetrics.controlsBottom)

                HStack(spacing: 8) {
                    if !model.recordedDisplays.isEmpty {
                        displayPicker
                    }
                    Spacer()
                    if let context = model.currentContext, context.bundleID != nil || context.url != nil {
                        openButton(for: context)
                    }
                    zoomControl
                    overflow
                }
                .padding(.trailing, 24)
                .padding(.bottom, TimelineMetrics.controlsBottom)

                // Sits at the end of the strip, which is where "now" is.
                if !model.isAtNow {
                    HStack {
                        Spacer()
                        Button(action: onJumpToNow) {
                            Image(systemName: "arrow.right")
                        }
                        .buttonStyle(ChromeIconStyle())
                        .help("Back to now")
                        .accessibilityLabel("Back to now")
                        .keyboardShortcut(.end, modifiers: [])
                    }
                    .padding(.trailing, 24)
                    .padding(.bottom, TimelineMetrics.stripCenter - 18)
                }

                if let hover = model.hover, model.slice == nil {
                    StripHoverCard(hover: hover)
                        .position(
                            x: min(max(hover.x, 240), geometry.size.width - 240),
                            // Above the time pill, which is what's being read while moving along.
                            y: geometry.size.height - TimelineMetrics.controlsBottom - 74
                        )
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }

                if let slice = model.slice {
                    SliceBar(
                        model: model,
                        slice: slice,
                        actions: sliceActions,
                        onZoomToSlice: onZoomToSlice,
                        onClear: onClearSlice
                    )
                    .padding(.bottom, TimelineMetrics.controlsBottom + 44)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                }

                if let toast = model.toast {
                    Text(toast)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(Color(white: 0.12).opacity(0.96), in: Capsule())
                        .overlay(Capsule().strokeBorder(.white.opacity(0.1)))
                        .padding(.bottom, TimelineMetrics.controlsBottom + (model.slice == nil ? 44 : 100))
                        .transition(.opacity)
                        .allowsHitTesting(false)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .animation(.easeOut(duration: 0.15), value: model.slice != nil)
            .animation(.easeOut(duration: 0.15), value: model.toast)
        }
        .overlay {
            if model.isEmpty {
                VStack(spacing: 6) {
                    Text("Nothing recorded on this display yet")
                        .font(.system(size: 17, weight: .semibold))
                    Text("Elodie records the display your pointer is on.")
                        .font(.system(size: 13))
                        .opacity(0.7)
                }
                .foregroundStyle(.white)
            }
        }
    }

    private var timePill: some View {
        Button {
            model.isJumpToDateOpen.toggle()
        } label: {
            HStack(spacing: 6) {
                if model.isStarred {
                    Image(systemName: "star.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.marker)
                }
                Text(model.timeLabel)
                    .monospacedDigit()
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white.opacity(0.7))
            }
        }
        .buttonStyle(ChromeControlStyle())
        .accessibilityLabel("Jump to a date and time. Showing \(model.timeLabel).")
    }

    /// Recording follows the pointer, so each display has its own history. This only shows
    /// when there's more than one.
    private var displayPicker: some View {
        Button {
            let menu = NSMenu()
            for choice in model.recordedDisplays {
                let item = DisplayMenuItem(choice: choice, onChoose: onChooseDisplay)
                item.state = choice.id == model.shownDisplay ? .on : .off
                menu.addItem(item)
            }
            menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "display")
                    .font(.system(size: 13))
                Text(model.recordedDisplays.first { $0.id == model.shownDisplay }?.name ?? String(localized: "Display"))
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white.opacity(0.7))
            }
        }
        .buttonStyle(ChromeControlStyle())
        .padding(.leading, 24)
        .help("Choose which display's history to look through")
    }

    /// A magnifier that opens into a slider, with the widest and closest views at each end.
    private var zoomControl: some View {
        HStack(spacing: 8) {
            if model.isZoomOpen {
                Slider(
                    value: Binding(
                        get: { model.zoomFraction },
                        set: { onZoom($0) }
                    ),
                    in: 0...1
                )
                .frame(width: 130)
                .tint(.white)
                .controlSize(.small)
                .padding(.leading, 12)
                .accessibilityLabel("Zoom")
            }
            Button {
                withAnimation(.easeOut(duration: 0.15)) { model.isZoomOpen.toggle() }
            } label: {
                Image(systemName: "plus.magnifyingglass")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Zoom the timeline. You can also pinch, or press ⌘+ and ⌘−.")
            .accessibilityLabel("Zoom the timeline")
        }
        .background(.black.opacity(ChromeMetrics.controlFillOpacity), in: Capsule())
        .glassEffect(.regular.interactive(), in: .capsule)
        .environment(\.colorScheme, .dark)
    }

    private func openButton(for context: FrameContext) -> some View {
        Button(action: onOpen) {
            HStack(spacing: 6) {
                if let icon = Self.appIcon(for: context.bundleID) {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: 18, height: 18)
                }
                Text("Open")
            }
        }
        .buttonStyle(ChromeControlStyle())
        .help(context.url ?? "Open the app")
    }

    fileprivate static func appIcon(for bundleID: String?) -> NSImage? {
        guard let bundleID,
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        else { return nil }
        return NSWorkspace.shared.icon(forFile: url.path)
    }

    fileprivate static func appName(for bundleID: String?) -> String? {
        guard let bundleID else { return nil }
        return NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)?
            .deletingPathExtension().lastPathComponent ?? bundleID
    }
}

private final class DisplayMenuItem: NSMenuItem {
    private let choice: DisplayChoice
    private let onChoose: (UUID) -> Void

    init(choice: DisplayChoice, onChoose: @escaping (UUID) -> Void) {
        self.choice = choice
        self.onChoose = onChoose
        super.init(title: choice.name, action: #selector(choose), keyEquivalent: "")
        target = self
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("Not used") }

    @objc private func choose() { onChoose(choice.id) }
}

/// What the pointer is over on the strip.
private struct StripHoverCard: View {
    let hover: StripHover

    private var title: String {
        if hover.isBreak { return String(localized: "Nothing recorded") }
        return hover.window ?? TimelineChrome.appName(for: hover.bundleID) ?? String(localized: "Recording")
    }

    var body: some View {
        HStack(spacing: 10) {
            if let icon = TimelineChrome.appIcon(for: hover.bundleID) {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 26, height: 26)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Text("\(SliceDescription.range(DateInterval(start: hover.start, end: max(hover.end, hover.start)))), \(SliceDescription.duration(hover.end.timeIntervalSince(hover.start)))")
                    .font(.system(size: 12))
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(0.7))
                    .lineLimit(1)
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        // Wide enough for a date, a range with seconds, and a length, all on one line.
        .frame(maxWidth: 460, alignment: .leading)
        .background(Color(white: 0.12).opacity(0.97), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.white.opacity(0.1)))
        .shadow(color: .black.opacity(0.4), radius: 10, y: 4)
        .fixedSize()
    }
}

/// What's been picked out on the strip, and what can be done with it.
private struct SliceBar: View {
    @Bindable var model: TimelineModel
    let slice: DateInterval
    let actions: SliceActions
    let onZoomToSlice: () -> Void
    let onClear: () -> Void
    @State private var failure: String?

    private var singleApp: String? {
        guard let apps = model.sliceSummary?.apps, apps.count == 1 else { return nil }
        return apps[0].bundleID
    }

    var body: some View {
        VStack(spacing: 8) {
            if model.isConfirmingDelete {
                confirmation
            }
            HStack(spacing: 2) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(SliceDescription.duration(model.sliceRecordedTime))
                        .font(.system(size: 13, weight: .semibold))
                    Text(subtitle)
                        .font(.system(size: 11))
                        .monospacedDigit()
                        .foregroundStyle(.white.opacity(0.65))
                        .lineLimit(1)
                }
                .padding(.leading, 14)
                .padding(.trailing, 10)

                divider
                action("Star", symbol: "star") { actions.star(slice) }
                action("Export", symbol: "square.and.arrow.up") { actions.export(slice) }
                action("Fit", symbol: "arrow.left.and.right") { onZoomToSlice() }
                if let singleApp, let name = TimelineChrome.appName(for: singleApp) {
                    action("Exclude \(name)", symbol: "eye.slash") { actions.exclude(singleApp) }
                }
                divider
                action("Delete", symbol: "trash", isDestructive: true) {
                    model.isConfirmingDelete = true
                }
                Button(action: onClear) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white.opacity(0.7))
                        .frame(width: 30, height: 34)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Clear the selection")
                .accessibilityLabel("Clear the selection")
                .padding(.trailing, 4)
            }
            .padding(.vertical, 5)
            .foregroundStyle(.white)
            .background(Color(white: 0.12).opacity(0.97), in: Capsule())
            .overlay(Capsule().strokeBorder(.white.opacity(0.12)))
            .shadow(color: .black.opacity(0.4), radius: 14, y: 5)
        }
        .environment(\.colorScheme, .dark)
    }

    private var subtitle: String {
        guard let summary = model.sliceSummary else { return SliceDescription.range(slice) }
        return "\(SliceDescription.range(slice)), \(summary.bytes.formatted(.byteCount(style: .file)))"
    }

    private var divider: some View {
        Rectangle()
            .fill(.white.opacity(0.14))
            .frame(width: 1, height: 22)
            .padding(.horizontal, 4)
    }

    private func action(
        _ title: LocalizedStringKey,
        symbol: String,
        isDestructive: Bool = false,
        perform: @escaping () -> Void
    ) -> some View {
        Button(action: perform) {
            HStack(spacing: 5) {
                Image(systemName: symbol)
                    .font(.system(size: 12, weight: .medium))
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
            }
            .foregroundStyle(isDestructive ? Color(red: 1, green: 0.5, blue: 0.45) : .white)
            .padding(.horizontal, 9)
            .frame(height: 30)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Deleting can't be undone, so this says exactly what goes, in place. A separate alert
    /// window wouldn't work over a panel that never activates.
    private var confirmation: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Delete \(SliceDescription.duration(model.sliceRecordedTime)) of recordings?")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
            if let summary = model.sliceSummary {
                Text(SliceDescription.deletionDetails(slice, summary: summary))
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.75))
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ProgressView().controlSize(.small)
            }
            if let failure {
                Label(failure, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.marker)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("This can't be undone.")
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.55))
            HStack {
                Spacer()
                if model.isDeleting {
                    ProgressView().controlSize(.small)
                }
                Button("Cancel") { model.isConfirmingDelete = false }
                    .keyboardShortcut(.cancelAction)
                    .disabled(model.isDeleting)
                Button("Delete", role: .destructive) { delete() }
                    .buttonStyle(DestructiveActionStyle())
                    .disabled(model.isDeleting || model.sliceSummary == nil)
            }
        }
        .padding(16)
        .frame(width: 380)
        .background(Color(white: 0.12).opacity(0.98), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.white.opacity(0.12)))
        .shadow(color: .black.opacity(0.45), radius: 18, y: 6)
    }

    private func delete() {
        model.isDeleting = true
        failure = nil
        let slice = self.slice
        let recordedTime = model.sliceRecordedTime
        Task {
            do {
                try await actions.delete(slice)
                model.isDeleting = false
                model.isConfirmingDelete = false
                model.showToast(String(localized: "Deleted \(SliceDescription.duration(recordedTime))"))
                onClear()
            } catch {
                model.isDeleting = false
                failure = String(localized: "It couldn't be deleted: \(error.localizedDescription)")
            }
        }
    }
}
