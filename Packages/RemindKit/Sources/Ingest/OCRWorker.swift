import CoreAPI
import CoreGraphics
import CoreText
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
    private static let batchSize = 8
    /// How long to wait for new work once the queue is empty.
    private static let idleDelay: Duration = .seconds(2)

    private let core: any RemindCore
    private let lock = NSLock()
    private var task: Task<Void, Never>?
    private var processed = 0
    private var warmingUp = false
    private var backfillAllowed = true
    private var additionalLanguages = false

    public init(core: any RemindCore) {
        self.core = core
    }

    public var framesProcessed: Int {
        lock.withLock { processed }
    }

    /// Whether text recognition is still getting ready, which took about 30 seconds the
    /// first time on an M4 Max, and will take longer on slower Macs. Until it finishes, new
    /// recordings can't be found by their text yet.
    public var isWarmingUp: Bool {
        lock.withLock { warmingUp }
    }

    /// Whether frames set aside earlier may be read. This stays off when disk space is
    /// low, since reading them adds to the index.
    public var allowsBackfill: Bool {
        get { lock.withLock { backfillAllowed } }
        set { lock.withLock { backfillAllowed = newValue } }
    }

    /// Whether to detect any language, which is slower, instead of the ones this Mac uses.
    public var usesAdditionalLanguages: Bool {
        get { lock.withLock { additionalLanguages } }
        set { lock.withLock { additionalLanguages = newValue } }
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

    /// The first recognition under a new app identity compiles Vision's models for the
    /// Neural Engine. It happens here, on a small picture, so no
    /// recorded frame uses up an attempt on it. Frames wait safely in the log meanwhile.
    private func warmUp() async {
        guard let image = Self.warmUpImage() else { return }
        lock.withLock { warmingUp = true }
        let box = PixelBufferBox(image)
        // It's a one-time wait that someone may be watching, so it doesn't run at low priority.
        _ = await Task.detached(priority: .userInitiated) {
            try? await Self.recognize(box.buffer)
        }.value
        lock.withLock { warmingUp = false }
    }

    /// A few words, so that both finding text and reading it get compiled.
    private static func warmUpImage() -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(
            nil, 480, 120, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary,
            &buffer
        )
        guard let buffer else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer),
            width: 480,
            height: 120,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 480, height: 120))
        let font = CTFontCreateWithName("Helvetica" as CFString, 32, nil)
        let text = NSAttributedString(string: "Getting ready to read", attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1),
        ])
        context.textPosition = CGPoint(x: 24, y: 44)
        CTLineDraw(CTLineCreateWithAttributedString(text), context)
        return buffer
    }

    private func run() async {
        await warmUp()
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
        let idle = !ProcessInfo.processInfo.isLowPowerModeEnabled && allowsBackfill
        let jobs = try core.nextOCRBatch(max: Self.batchSize, now: Date(), includeDeferred: idle)
        guard !jobs.isEmpty else { return false }

        var results: [OCRResult] = []
        for job in jobs {
            do {
                let image = try reader.image(for: job.frameID)
                let lines = try await Self.recognize(image, additionalLanguages: usesAdditionalLanguages)
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
    ///
    /// There's deliberately no timeout. Vision can't be cancelled: cancelling only abandons
    /// the call, which keeps running and holds Vision's lock, so timed-out calls pile up
    /// and each uses up one of a frame's attempts. If a frame ever hangs here, its attempt
    /// is already recorded, so it gets retired after a few launches and OCR moves on.
    static func recognize(_ image: CVPixelBuffer, additionalLanguages: Bool = false) async throws -> [RecognizedLine] {
        var request = RecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        request.minimumTextHeightFraction = 0
        if additionalLanguages {
            request.automaticallyDetectsLanguage = true
        } else {
            // Vision only reads English unless told otherwise.
            let supported = request.supportedRecognitionLanguages
            let preferred = Locale.preferredLanguages.map(Locale.Language.init(identifier:)).filter { language in
                supported.contains { $0.languageCode == language.languageCode }
            }
            if !preferred.isEmpty {
                request.recognitionLanguages = preferred
            }
        }
        let box = PixelBufferBox(image)
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
