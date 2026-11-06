import CoreAPI
import CoreVideo
import Foundation

/// What the scrub engine shows, and why.
public struct ScrubUpdate: @unchecked Sendable {
    public let frame: DecodedFrame
    /// Whether this is exactly the frame asked for, rather than a nearby stand-in
    /// while scrubbing fast or waiting for a decode.
    public let isExact: Bool
    /// The time this update was asked for.
    public let requested: Date
}

/// Finds and decodes the frame for wherever the playhead is.
///
/// Scrubbing outruns decoding, so this always works on the latest request and skips
/// any in between. It has three modes:
///
/// - **Exact**, when the playhead is slow enough to decode every frame. A miss
///   decodes from the group's keyframe, and everything decoded stays cached.
/// - **Keyframes only**, when it's moving faster than frames can decode. Each jump
///   decodes one picture, so the screen keeps moving.
/// - **Settling**, when it stops. The exact frame gets decoded, then the groups on
///   either side, so the next step in either direction is instant.
///
/// The picture never blanks: until the right frame is ready, the closest cached one
/// stays up. The time label and strip follow the playhead directly, so they never lag.
public final class ScrubEngine: @unchecked Sendable {
    public struct Request: Equatable, Sendable {
        public var time: Date
        /// Frames per second, positive going forward. Decides the mode.
        public var velocity: Double

        public init(time: Date, velocity: Double) {
            self.time = time
            self.velocity = velocity
        }
    }

    private static let settleDelay: TimeInterval = 0.06
    /// A starting guess until real decodes have been measured.
    private static let initialDecodeRate: Double = 120

    private let core: any ElodieCore
    private let display: UUID
    private let queue = DispatchQueue(label: "elodie.scrub", qos: .userInteractive)
    private let lock = NSLock()
    private var latest: Request?
    private var isPumping = false
    private var generation = 0
    private var settleWork: DispatchWorkItem?

    // Everything below is owned by `queue`.
    private let cache: FrameCache
    private var decodeRate = ScrubEngine.initialDecodeRate
    private var lastTarget: Int64?
    private var shown: Int64?
    private var direction = 0
    /// A decoder partway through a group, so moving forward can continue from it.
    private var open: OpenGroup?

    private struct OpenGroup {
        let decoder: HEVCDecoder
        let group: GroupOfPictures
        var nextIndex: Int
    }

    /// Called on the engine's queue with what to show.
    public var onUpdate: (@Sendable (ScrubUpdate) -> Void)?

    public init(core: any ElodieCore, display: UUID, budget: Int? = nil) {
        self.core = core
        self.display = display
        cache = FrameCache(budget: budget ?? Self.defaultBudget())
    }

    /// 10% of memory, kept between limits that suit both small and large machines.
    public static func defaultBudget(physicalMemory: UInt64 = ProcessInfo.processInfo.physicalMemory) -> Int {
        let tenth = Int(physicalMemory / 10)
        return min(max(tenth, 700_000_000), 1_400_000_000)
    }

    /// Moves the playhead. Safe to call from any thread at any rate, and it returns
    /// immediately.
    public func seek(_ request: Request) {
        let shouldStart = lock.withLock { () -> Bool in
            latest = request
            generation += 1
            settleWork?.cancel()
            settleWork = nil
            if isPumping { return false }
            isPumping = true
            return true
        }
        if shouldStart {
            queue.async { self.pump() }
        }
    }

    /// Waits for everything queued so far. For tests and benchmarks.
    public func waitUntilIdle() {
        queue.sync {}
    }

    /// Forgets every decoded picture, including the one on show. Recordings have been deleted,
    /// and a picture that no longer exists mustn't be shown again.
    public func forgetEverything() {
        queue.async {
            self.open = nil
            self.shown = nil
            self.lastTarget = nil
            self.cache.pin([])
            let budget = self.cache.budget
            self.cache.budget = 0
            self.cache.evict(target: 0, direction: 0)
            self.cache.budget = budget
        }
    }

    /// Empties the cache, as when memory is short.
    public func purge() {
        queue.async {
            self.open = nil
            let pinned = self.shown.map { Set([$0]) } ?? []
            self.cache.pin(pinned)
            let budget = self.cache.budget
            self.cache.budget = 0
            self.cache.evict(target: self.shown ?? 0, direction: 0)
            self.cache.budget = budget
        }
    }

    private func takeLatest() -> (request: Request, generation: Int)? {
        lock.withLock {
            guard let request = latest else {
                isPumping = false
                return nil
            }
            latest = nil
            return (request, generation)
        }
    }

    private var hasNewerRequest: Bool {
        lock.withLock { latest != nil }
    }

    private func pump() {
        var last: (request: Request, generation: Int)?
        while let next = takeLatest() {
            last = next
            handle(next.request)
        }
        if let last { scheduleSettle(last.request, generation: last.generation) }
    }

    private func handle(_ request: Request) {
        guard let frame = try? core.lookup(display: display, at: request.time) else { return }

        if let previous = lastTarget, previous != frame.id {
            direction = frame.id > previous ? 1 : -1
        }
        lastTarget = frame.id

        if let cached = cache.frame(frame.id) {
            show(cached, isExact: true, request: request)
            return
        }

        // Too fast to decode every frame, so settle for keyframes.
        if abs(request.velocity) > decodeRate / 2 {
            showKeyframe(frame, request: request)
            return
        }

        // Show the closest thing on hand while the real frame decodes.
        if let nearby = cache.nearest(to: frame.id, notBehind: shown) {
            show(nearby, isExact: false, request: request)
        }
        decodeExact(frame, request: request)
    }

    private func show(_ frame: DecodedFrame, isExact: Bool, request: Request) {
        shown = frame.frameID
        cache.pin([frame.frameID])
        onUpdate?(ScrubUpdate(frame: frame, isExact: isExact, requested: request.time))
    }

    private func showKeyframe(_ frame: FrameRef, request: Request) {
        do {
            let group = try core.readKeyframe(of: frame.id)
            guard let sample = group.samples.first else { return }
            if let cached = cache.frame(sample.frameID) {
                show(cached, isExact: sample.frameID == frame.id, request: request)
                return
            }
            let decoder = try HEVCDecoder(parameterSets: group.parameterSets, width: group.width, height: group.height)
            let started = Date()
            let image = try decoder.decode(sample.data)
            measure(frames: 1, since: started)
            let decoded = DecodedFrame(frameID: sample.frameID, capturedAt: sample.capturedAt, buffer: image)
            cache.insert(decoded, target: frame.id, direction: direction)
            show(decoded, isExact: sample.frameID == frame.id, request: request)
        } catch {
            // Keep showing what's there. The next request may well succeed.
        }
    }

    private func decodeExact(_ frame: FrameRef, request: Request) {
        do {
            if var open, let index = open.group.samples.firstIndex(where: { $0.frameID == frame.id }),
               index >= open.nextIndex {
                // Already partway through this group, so carry on from there.
                try decode(&open, through: index, target: frame.id, request: request)
                self.open = open
                return
            }
            let group = try core.readGroup(containing: frame.id)
            let decoder = try HEVCDecoder(parameterSets: group.parameterSets, width: group.width, height: group.height)
            var fresh = OpenGroup(decoder: decoder, group: group, nextIndex: 0)
            try decode(&fresh, through: group.target, target: frame.id, request: request)
            open = fresh
        } catch {
            open = nil
        }
    }

    /// Decodes up to `index`, and stops early if a newer request has moved on. A newer
    /// request inside this group is handled next by continuing from here, so finished
    /// work isn't thrown away.
    private func decode(_ open: inout OpenGroup, through index: Int, target: Int64, request: Request) throws {
        guard open.nextIndex <= index else { return }
        let started = Date()
        let samples = Array(open.group.samples[open.nextIndex...index])
        let images = try open.decoder.decode(samples.map(\.data)) { hasNewerRequest }
        measure(frames: images.count, since: started)
        open.nextIndex += images.count

        for (sample, image) in zip(samples, images) {
            let decoded = DecodedFrame(frameID: sample.frameID, capturedAt: sample.capturedAt, buffer: image)
            cache.insert(decoded, target: target, direction: direction)
            if sample.frameID == target {
                show(decoded, isExact: true, request: request)
            }
        }
    }

    /// Keeps a running estimate of how fast frames decode.
    private func measure(frames: Int, since started: Date) {
        guard frames > 0 else { return }
        let elapsed = Date().timeIntervalSince(started)
        guard elapsed > 0 else { return }
        decodeRate = decodeRate * 0.8 + (Double(frames) / elapsed) * 0.2
    }

    // MARK: Settling

    private func scheduleSettle(_ request: Request, generation: Int) {
        let work = DispatchWorkItem { [weak self] in self?.settle(request, generation: generation) }
        lock.withLock { settleWork = work }
        queue.asyncAfter(deadline: .now() + Self.settleDelay, execute: work)
    }

    /// Once the playhead has stopped: the exact frame, then the neighbouring groups,
    /// backward first, because going backward is what's expensive.
    ///
    /// A request can arrive between the pump finishing and this being scheduled, too
    /// late for `seek` to cancel it. The generation check stops a stale settle from
    /// jumping the picture back to where the playhead used to be.
    private func settle(_ request: Request, generation expected: Int) {
        guard lock.withLock({ generation == expected }),
              let frame = try? core.lookup(display: display, at: request.time)
        else { return }
        if cache.frame(frame.id) == nil {
            decodeExact(frame, request: request)
        } else if shown != frame.id, let cached = cache.frame(frame.id) {
            show(cached, isExact: true, request: request)
        }
        fill(around: frame, request: request)
    }

    private func fill(around frame: FrameRef, request: Request) {
        guard let group = try? core.readGroup(containing: frame.id) else { return }
        // The rest of this group first, then the group before, then the one after.
        try? decodeWhole(group, target: frame.id)

        if let first = group.samples.first, !hasNewerRequest,
           let previous = try? core.neighbour(of: first.frameID, forward: false),
           let before = try? core.readGroup(containing: previous.id) {
            try? decodeWhole(before, target: frame.id)
        }
        if let last = group.samples.last, !hasNewerRequest,
           let next = try? core.neighbour(of: last.frameID, forward: true),
           let after = try? core.readGroup(containing: next.id) {
            try? decodeWhole(after, target: frame.id)
        }
    }

    private func decodeWhole(_ group: GroupOfPictures, target: Int64) throws {
        // Nothing to do if the group's last frame is already here.
        if let last = group.samples.last, cache.frame(last.frameID) != nil,
           let first = group.samples.first, cache.frame(first.frameID) != nil {
            return
        }
        let decoder = try HEVCDecoder(parameterSets: group.parameterSets, width: group.width, height: group.height)
        let images = try decoder.decode(group.samples.map(\.data)) { hasNewerRequest }
        for (sample, image) in zip(group.samples, images) {
            cache.insert(
                DecodedFrame(frameID: sample.frameID, capturedAt: sample.capturedAt, buffer: image),
                target: target,
                direction: direction
            )
        }
    }
}
