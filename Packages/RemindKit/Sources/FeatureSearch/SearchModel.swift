import CoreAPI
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
    }

    private func restart() {
        session?.cancel()
        session = nil
        task?.cancel()
        generation += 1
        failure = nil
        let trimmed = text.trimmingCharacters(in: .whitespaces)
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

    /// Fetches more results. New ones go after what's already shown, and nothing moves.
    public func loadMore() {
        guard hasMore, !isSearching, let session else { return }
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
