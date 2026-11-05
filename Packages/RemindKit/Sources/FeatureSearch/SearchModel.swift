import CoreAPI
import CoreGraphics
import Foundation
import Observation

/// One search box's state: what's typed, the filters, and results as they arrive.
///
/// New text cancels the query in progress, so a slow query can't hold up the next
/// keystroke, and results from an old query can't land on a new one.
@MainActor
@Observable
public final class SearchModel {
    public enum Layout: Equatable, Sendable {
        case compact
        case expanded
    }

    public var layout = Layout.compact
    public var text = "" {
        didSet {
            if text != oldValue { restart() }
        }
    }
    public var selectedApps: Set<String> = [] {
        didSet {
            if selectedApps != oldValue { restart() }
        }
    }
    public var starredOnly = false {
        didSet {
            if starredOnly != oldValue { restart() }
        }
    }
    public var meetingsOnly = false {
        didSet {
            if meetingsOnly != oldValue { restart() }
        }
    }
    public private(set) var hits: [SearchHit] = []
    public private(set) var isSearching = false
    public private(set) var hasMore = false
    public private(set) var hasSearched = false
    public private(set) var failure: String?
    public private(set) var availableApps: [String] = []
    /// Which result the keyboard is on.
    public private(set) var selectedIndex: Int?
    public var isAppsOpen = false
    /// Why results might be missing right now, if there's a reason.
    @ObservationIgnored public var note: () -> String? = { nil }
    /// How many results fit in a row, so moving up and down goes where it looks like it should.
    @ObservationIgnored public var columnsPerRow = 1
    /// Where each card is on screen, so choosing one by keyboard can start from it too.
    @ObservationIgnored public var cardFrames: [String: CGRect] = [:]

    /// Whether this is listing what the filters pick out, with no words to search for.
    public var isBrowsing: Bool {
        text.trimmingCharacters(in: .whitespaces).isEmpty
            && (starredOnly || meetingsOnly || !selectedApps.isEmpty)
    }

    /// The result the keyboard is on, or the top one if it hasn't moved yet.
    public var chosenHit: SearchHit? {
        if let selectedIndex, hits.indices.contains(selectedIndex) { return hits[selectedIndex] }
        return hits.first
    }

    public func move(_ move: SearchMove) {
        guard !hits.isEmpty else { return }
        let step = switch move {
        case .next: 1
        case .previous: -1
        case .nextRow: columnsPerRow
        case .previousRow: -columnsPerRow
        }
        guard let selectedIndex else {
            self.selectedIndex = step > 0 ? 0 : nil
            return
        }
        self.selectedIndex = min(max(selectedIndex + step, 0), hits.count - 1)
        if hits.count - (self.selectedIndex ?? 0) < columnsPerRow * 2 { loadMore() }
    }

    /// Runs the current search again, because recordings have changed.
    public func refresh() {
        restart()
    }

    private let core: any RemindCore
    /// How long to wait after a keystroke, so typing doesn't start a query per letter.
    private let debounce: Duration
    private var task: Task<Void, Never>?
    private var session: (any SearchSession)?
    /// Identifies the current search, so a stale result can tell it's stale.
    private var generation = 0

    public init(core: any RemindCore, debounce: Duration = .milliseconds(60)) {
        self.core = core
        self.debounce = debounce
    }

    public func loadApps() {
        let core = self.core
        Task.detached(priority: .userInitiated) { [weak self] in
            let apps = (try? core.recordedApps()) ?? []
            await self?.setApps(apps)
        }
    }

    private func setApps(_ apps: [String]) {
        availableApps = apps
    }

    public func clear() {
        text = ""
        selectedApps = []
        starredOnly = false
        meetingsOnly = false
        layout = .compact
        isAppsOpen = false
        selectedIndex = nil
    }

    private func restart() {
        session?.cancel()
        session = nil
        task?.cancel()
        generation += 1
        failure = nil
        selectedIndex = nil
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if isBrowsing {
            browse()
            return
        }
        guard !trimmed.isEmpty else {
            hits = []
            hasMore = false
            isSearching = false
            hasSearched = false
            return
        }
        layout = .expanded
        isSearching = true
        let current = generation
        let core = self.core
        let query = text
        let facets = SearchFacets(bundleIDs: selectedApps.sorted(), starredOnly: starredOnly, transcriptsOnly: meetingsOnly)
        let wait = debounce
        task = Task { [weak self] in
            try? await Task.sleep(for: wait)
            guard !Task.isCancelled else { return }
            // The first page runs off the main thread, because it touches the disk.
            let outcome = await Task.detached(priority: .userInitiated) { () -> Result<(any SearchSession, SearchPage)?, any Error> in
                do {
                    guard let session = try core.search(query, facets: facets, order: .relevance) else {
                        return .success(nil)
                    }
                    return .success((session, try session.nextPage()))
                } catch {
                    return .failure(error)
                }
            }.value
            self?.finish(outcome, generation: current)
        }
    }

    private func finish(_ outcome: Result<(any SearchSession, SearchPage)?, any Error>, generation expected: Int) {
        guard expected == generation else { return }
        isSearching = false
        hasSearched = true
        switch outcome {
        case .success(let result):
            session = result?.0
            hits = result?.1.hits ?? []
            hasMore = result?.1.hasMore ?? false
        case .failure(let error):
            // Typing past a slow query cancels it, and that's not a failure.
            if !"\(error)".contains("interrupted") {
                failure = "Search couldn't finish. Try again."
            }
            hits = []
        }
    }

    private nonisolated static let browsePage = 30

    private var facets: SearchFacets {
        SearchFacets(bundleIDs: selectedApps.sorted(), starredOnly: starredOnly, transcriptsOnly: meetingsOnly)
    }

    /// Lists what the filters pick out, most recent first. This is how to see your starred
    /// moments or past meetings without having to remember a word from them.
    private func browse(before: Date? = nil) {
        layout = .expanded
        isSearching = true
        hasSearched = true
        let current = generation
        let core = self.core
        let facets = self.facets
        task = Task { [weak self] in
            let page = await Task.detached(priority: .userInitiated) {
                Result { try core.moments(facets: facets, before: before, limit: Self.browsePage) }
            }.value
            self?.finishBrowsing(page, generation: current, appending: before != nil)
        }
    }

    private func finishBrowsing(_ page: Result<[SearchHit], any Error>, generation expected: Int, appending: Bool) {
        guard expected == generation else { return }
        isSearching = false
        switch page {
        case .success(let found):
            hits = appending ? hits + found : found
            hasMore = found.count == Self.browsePage
        case .failure:
            failure = "That list couldn't be loaded. Try again."
            hits = []
            hasMore = false
        }
    }

    /// Fetches more results. New ones go after what's already shown, and nothing moves.
    public func loadMore() {
        guard hasMore, !isSearching else { return }
        if isBrowsing {
            browse(before: hits.last?.capturedAt)
            return
        }
        guard let session else { return }
        isSearching = true
        let current = generation
        Task { [weak self] in
            let page = await Task.detached(priority: .userInitiated) { try? session.nextPage() }.value
            self?.append(page, generation: current)
        }
    }

    private func append(_ page: SearchPage?, generation expected: Int) {
        guard expected == generation else { return }
        isSearching = false
        guard let page else {
            hasMore = false
            return
        }
        hits.append(contentsOf: page.hits)
        hasMore = page.hasMore
    }
}
