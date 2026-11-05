import CoreAPI
import CoreVideo
import Foundation
import FrameEngine
import Vision

/// Reads text from recorded frames in the background.
///
/// Frames come from the log rather than from live capture, so nothing has to be kept
/// in memory while OCR catches up, and the same path works after a crash. Spike 4
/// measures that reading stored frames doesn't lose text.
public final class OCRWorker: @unchecked Sendable {
    /// A frame that takes longer than this is given up on for this attempt.
    private static let timeout: Duration = .seconds(10)
    private static let batchSize = 8
    /// How long to wait for new work once the queue is empty.
    private static let idleDelay: Duration = .seconds(2)

    private let core: any RemindCore
    private let lock = NSLock()
    private var task: Task<Void, Never>?
    private var processed = 0

    public init(core: any RemindCore) {
        self.core = core
    }

    public var framesProcessed: Int {
        lock.withLock { processed }
    }

    public func start() {
        lock.withLock {
            guard task == nil else { return }
            task = Task.detached(priority: .utility) { [self] in
                await run()
            }
        }
    }

    public func stop() {
        lock.withLock {
            task?.cancel()
            task = nil
        }
    }

    /// Whether OCR should pause to let the machine cool. Capture keeps going, and
    /// frames wait safely in the log.
    private var isTooHot: Bool {
        let state = ProcessInfo.processInfo.thermalState
        return state == .serious || state == .critical
    }

    private func run() async {
        var reader = GroupReader(core: core)
        while !Task.isCancelled {
            if isTooHot {
                try? await Task.sleep(for: .seconds(30))
                continue
            }
            do {
                let worked = try await processBatch(&reader)
                if !worked {
                    try? await Task.sleep(for: Self.idleDelay)
                }
            } catch {
                try? await Task.sleep(for: Self.idleDelay)
            }
        }
    }

    /// Processes one batch, returning whether there was anything to do.
    func processBatch(_ reader: inout GroupReader) async throws -> Bool {
        // Frames set aside while OCR was behind only run on a quiet machine.
        let idle = !ProcessInfo.processInfo.isLowPowerModeEnabled
        let jobs = try core.nextOCRBatch(max: Self.batchSize, now: Date(), includeDeferred: idle)
        guard !jobs.isEmpty else { return false }

        var results: [OCRResult] = []
        for job in jobs {
            do {
                let image = try reader.image(for: job.frameID)
                let lines = try await Self.recognize(image)
                results.append(OCRResult(frameID: job.frameID, lines: lines))
            } catch {
                try core.failOCR(frameID: job.frameID)
            }
        }
        if !results.isEmpty {
            try core.submitOCR(results)
        }
        lock.withLock { processed += jobs.count }
        return true
    }

    /// Reads a frame's text. Language correction stays off because it "fixes" code,
    /// names, and part numbers, and a minimum height of zero keeps small text.
    static func recognize(_ image: CVPixelBuffer) async throws -> [RecognizedLine] {
        let box = PixelBufferBox(image)
        return try await withThrowingTaskGroup(of: [RecognizedLine].self) { group in
            group.addTask {
                var request = RecognizeTextRequest()
                request.recognitionLevel = .accurate
                request.usesLanguageCorrection = false
                request.minimumTextHeightFraction = 0
                let observations = try await request.perform(on: box.buffer, orientation: nil)
                return observations.compactMap { observation in
                    guard let text = observation.topCandidates(1).first?.string else { return nil }
                    let box = observation.boundingBox
                    return RecognizedLine(
                        text: text,
                        rect: CGRect(
                            x: box.origin.x,
                            // Vision's origin is at the bottom left, and ours is at the top left.
                            y: 1 - box.origin.y - box.height,
                            width: box.width,
                            height: box.height
                        )
                    )
                }
            }
            group.addTask {
                try await Task.sleep(for: Self.timeout)
                throw CancellationError()
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else {
                throw CancellationError()
            }
            return first
        }
    }
}

private struct PixelBufferBox: @unchecked Sendable {
    let buffer: CVPixelBuffer
    init(_ buffer: CVPixelBuffer) { self.buffer = buffer }
}

/// Decodes frames for OCR, continuing from the last one when it can. P-frames need
/// every earlier frame in their group, so going forward avoids repeating that work.
struct GroupReader {
    private let core: any RemindCore
    private var decoder: HEVCDecoder?
    private var group: GroupOfPictures?
    private var nextIndex = 0
    private var lastImage: CVPixelBuffer?

    init(core: any RemindCore) {
        self.core = core
    }

    mutating func image(for frameID: Int64) throws -> CVPixelBuffer {
        // Continue through the current group if the frame is ahead in it.
        if let group, let decoder,
           let index = group.samples.firstIndex(where: { $0.frameID == frameID }), index >= nextIndex - 1 {
            if index == nextIndex - 1, let lastImage {
                return lastImage
            }
            var image: CVPixelBuffer?
            for position in nextIndex...index {
                image = try decoder.decode(group.samples[position].data)
            }
            nextIndex = index + 1
            lastImage = image
            if let image { return image }
        }

        let loaded = try core.readGroup(containing: frameID)
        let fresh = try HEVCDecoder(parameterSets: loaded.parameterSets, width: loaded.width, height: loaded.height)
        var image: CVPixelBuffer?
        for sample in loaded.samples[...loaded.target] {
            image = try fresh.decode(sample.data)
        }
        guard let image else { throw DecoderError.noImage }
        decoder = fresh
        group = loaded
        nextIndex = loaded.target + 1
        lastImage = image
        return image
    }
}
