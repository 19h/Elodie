import AppKit
import CoreAPI
import DesignSystem
import SwiftUI

/// The floating search panel: a box and filters, which grow into a results grid.
public struct SearchPanel: View {
    @Bindable private var model: SearchModel
    private let thumbnail: (SearchHit) -> AnyView
    private let onSelect: (SearchHit, CGRect) -> Void
    private let onOpen: (SearchHit) -> Void
    private let field: AnyView

    @State private var isAppsOpen = false
    @State private var gridWidth: CGFloat = 0

    private static let cardWidth: CGFloat = 300
    private static let cardSpacing: CGFloat = 16

    public init(
        model: SearchModel,
        field: AnyView,
        thumbnail: @escaping (SearchHit) -> AnyView,
        onSelect: @escaping (_ hit: SearchHit, _ cardFrame: CGRect) -> Void,
        onOpen: @escaping (SearchHit) -> Void
    ) {
        self.model = model
        self.field = field
        self.thumbnail = thumbnail
        self.onSelect = onSelect
        self.onOpen = onOpen
    }

    public var body: some View {
        ReadingSurface {
            VStack(alignment: .leading, spacing: 0) {
                header
                filters
                if model.layout == .expanded {
                    Divider().overlay(.white.opacity(0.08))
                    results
                }
            }
        }
        .frame(maxWidth: model.layout == .expanded ? 1040 : 500)
        .frame(maxHeight: model.layout == .expanded ? .infinity : nil, alignment: .top)
        .shadow(color: .black.opacity(0.4), radius: 30, y: 12)
        .animation(.smooth(duration: 0.2), value: model.layout)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(.white.opacity(0.65))
            field
                .frame(height: 30)
            Button {
                model.layout = model.layout == .compact ? .expanded : .compact
            } label: {
                Image(systemName: model.layout == .compact
                      ? "arrow.up.left.and.arrow.down.right"
                      : "arrow.down.right.and.arrow.up.left")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.6))
            }
            .buttonStyle(.plain)
            .help(model.layout == .compact ? "Show results" : "Hide results")
        }
        .padding(.horizontal, 18)
        .padding(.top, 16)
        .padding(.bottom, 12)
    }

    private var filters: some View {
        HStack(spacing: 8) {
            appsChip
            toggleChip("Meetings", symbol: "calendar", isOn: $model.meetingsOnly)
            toggleChip("Starred", symbol: model.starredOnly ? "star.fill" : "star", isOn: $model.starredOnly)
            Spacer()
        }
        .padding(.horizontal, 18)
        .padding(.bottom, 14)
    }

    private var appsChip: some View {
        Button {
            model.loadApps()
            isAppsOpen.toggle()
        } label: {
            chipLabel(
                model.selectedApps.isEmpty ? "Apps" : "\(model.selectedApps.count) apps",
                symbol: "square.grid.2x2",
                isOn: !model.selectedApps.isEmpty,
                showsChevron: true
            )
        }
        .buttonStyle(.plain)
        .overlay(alignment: .topLeading) {
            if isAppsOpen {
                AppFilterList(apps: model.availableApps, selection: $model.selectedApps)
                    .offset(y: 40)
                    .zIndex(10)
            }
        }
    }

    private func toggleChip(_ title: LocalizedStringKey, symbol: String, isOn: Binding<Bool>) -> some View {
        Button {
            isOn.wrappedValue.toggle()
        } label: {
            chipLabel(title, symbol: symbol, isOn: isOn.wrappedValue, showsChevron: false)
        }
        .buttonStyle(.plain)
    }

    private func chipLabel(
        _ title: LocalizedStringKey,
        symbol: String,
        isOn: Bool,
        showsChevron: Bool
    ) -> some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
            Text(title)
            if showsChevron {
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold))
            }
        }
        .font(.system(size: 13, weight: .semibold))
        .foregroundStyle(isOn ? Palette.onVerdigris : .white.opacity(0.85))
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            isOn ? AnyShapeStyle(Palette.verdigris) : AnyShapeStyle(.white.opacity(0.1)),
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
    }

    @ViewBuilder
    private var results: some View {
        if let failure = model.failure {
            message(LocalizedStringKey(failure))
        } else if model.hits.isEmpty {
            if model.isSearching {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.hasSearched {
                message("No matches. Try fewer words, or check the filters.")
            } else {
                message("Type a word you remember seeing.")
            }
        } else {
            ScrollView {
                // Fixed columns, as many as there are results to fill, so a few results sit
                // together in the middle.
                let perRow = max(1, Int((gridWidth + Self.cardSpacing) / (Self.cardWidth + Self.cardSpacing)))
                let columns = Array(
                    repeating: GridItem(.fixed(Self.cardWidth), spacing: Self.cardSpacing),
                    count: min(model.hits.count, perRow)
                )
                LazyVGrid(columns: columns, spacing: 20) {
                    ForEach(model.hits) { hit in
                        ResultCard(
                            hit: hit,
                            thumbnail: thumbnail(hit),
                            onSelect: { onSelect(hit, $0) },
                            onOpen: { onOpen(hit) }
                        )
                        .onAppear {
                            if hit == model.hits.last { model.loadMore() }
                        }
                    }
                }
                .padding(18)
                .frame(maxWidth: .infinity)
            }
            .onGeometryChange(for: CGFloat.self, of: { $0.size.width - 36 }) { gridWidth = $0 }
        }
    }

    private func message(_ text: LocalizedStringKey) -> some View {
        Text(text)
            .font(.system(size: 14))
            .foregroundStyle(.white.opacity(0.6))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// One result: a crop centred on the match, what it was in, and when.
struct ResultCard: View {
    let hit: SearchHit
    let thumbnail: AnyView
    let onSelect: (CGRect) -> Void
    let onOpen: () -> Void
    @State private var isHovering = false
    @State private var frameOnScreen = CGRect.zero

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button { onSelect(frameOnScreen) } label: {
                ZStack(alignment: .bottom) {
                    thumbnail
                        .frame(height: 170)
                        .frame(maxWidth: .infinity)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .strokeBorder(.white.opacity(isHovering ? 0.35 : 0.1))
                        )
                    if isHovering, let name = appName {
                        Button(action: onOpen) {
                            Text("Open in \(name)")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(.black)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(.white.opacity(0.92), in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .padding(.bottom, 10)
                    }
                }
                .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }) { frameOnScreen = $0 }
            }
            .buttonStyle(.plain)

            HStack(spacing: 8) {
                if let icon {
                    Image(nsImage: icon).resizable().frame(width: 28, height: 28)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(hit.window ?? appName ?? "Unknown")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text(TimeLabel.text(for: hit.capturedAt, now: Date()))
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.6))
                        .lineLimit(1)
                }
            }
        }
        .onHover { isHovering = $0 }
    }

    private var applicationURL: URL? {
        hit.bundleID.flatMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }
    }

    private var appName: String? {
        applicationURL.map { $0.deletingPathExtension().lastPathComponent }
    }

    private var icon: NSImage? {
        applicationURL.map { NSWorkspace.shared.icon(forFile: $0.path) }
    }
}

/// Picks which apps to search in.
struct AppFilterList: View {
    let apps: [String]
    @Binding var selection: Set<String>

    var body: some View {
        ReadingSurface(cornerRadius: 12) {
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    if apps.isEmpty {
                        Text("Nothing recorded yet")
                            .font(.system(size: 13))
                            .foregroundStyle(.white.opacity(0.6))
                            .padding(10)
                    }
                    ForEach(apps, id: \.self) { bundleID in
                        row(bundleID)
                    }
                }
                .padding(6)
            }
        }
        .frame(width: 240)
        .frame(maxHeight: 280)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func row(_ bundleID: String) -> some View {
        let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        let name = url?.deletingPathExtension().lastPathComponent ?? bundleID
        return Button {
            if selection.contains(bundleID) {
                selection.remove(bundleID)
            } else {
                selection.insert(bundleID)
            }
        } label: {
            HStack(spacing: 8) {
                if let url {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                        .resizable()
                        .frame(width: 18, height: 18)
                }
                Text(name)
                    .font(.system(size: 13))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Spacer()
                if selection.contains(bundleID) {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Palette.verdigris)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
