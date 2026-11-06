// Test support, which has no place in a release build.
#if DEBUG
import CoreGraphics
import CoreText
import CoreVideo
import Foundation
import VideoToolbox

/// A deterministic stand-in for a real screen.
///
/// It draws editors, articles, terminals, tables, and video regions, and cycles
/// between them like someone switching apps. The same seed always gives the same
/// frames, and every frame knows its exact text, which gives OCR measurements a
/// ground truth. It records nothing real, so tests need no permissions.
///
/// Real usage will differ, so numbers from this are only an estimate until they
/// can be compared with a week of actual recording.
public final class SyntheticScreen {
    public struct Frame {
        public let pixelBuffer: CVPixelBuffer
        /// The same picture before conversion to 4:2:0, for comparing formats.
        public let fullColorBuffer: CVPixelBuffer
        public let index: Int
        public let scene: String
        /// Whether the scene changed on this frame, as when switching apps.
        public let isSceneChange: Bool
        /// Every word drawn in this frame.
        public let words: Set<String>
    }

    public enum Scene: String, CaseIterable, Sendable {
        case editor, article, terminal, table, video
    }

    public let width: Int
    public let height: Int
    private let scale: CGFloat
    private var rng: SeededGenerator
    private let vocabulary: [String]
    private let transfer: VTPixelTransferSession
    private var index = 0
    private var scene: Scene = .editor
    private var ticksUntilSwitch = 45

    // Per-scene state, so returning to an app shows what it showed before.
    private var editorLines: [String] = []
    private var terminalLines: [String] = []
    private var articleParagraphs: [String] = []
    private var articleOffset: CGFloat = 0
    private var tableCells: [[String]] = []

    /// Where the frame number is drawn.
    public var barcodeY: Int { Int(30 * scale) }

    public init(width: Int, height: Int, scale: CGFloat = 2, seed: UInt64 = 42) {
        self.width = width
        self.height = height
        self.scale = scale
        self.rng = SeededGenerator(seed: seed)
        self.vocabulary = Self.loadVocabulary()

        var session: VTPixelTransferSession?
        VTPixelTransferSessionCreate(allocator: nil, pixelTransferSessionOut: &session)
        self.transfer = session!

        articleParagraphs = (0..<40).map { _ in sentence(words: 60...120) }
        tableCells = (0..<36).map { _ in (0..<8).map { _ in randomWord() } }
    }

    private static func loadVocabulary() -> [String] {
        let fallback = [
            "memory", "timeline", "recording", "document", "meeting", "project", "search", "window",
            "display", "history", "keyboard", "network", "summary", "contract", "budget", "invoice",
            "schedule", "customer", "research", "analysis", "language", "function", "variable",
        ]
        guard let text = try? String(contentsOfFile: "/usr/share/dict/words", encoding: .utf8) else {
            return fallback
        }
        let words = text.split(separator: "\n").map(String.init).filter {
            $0.count >= 4 && $0.count <= 10 && $0.first?.isLowercase == true
        }
        return words.isEmpty ? fallback : words
    }

    private func randomWord() -> String {
        vocabulary[Int.random(in: 0..<vocabulary.count, using: &rng)]
    }

    private func sentence(words: ClosedRange<Int>) -> String {
        (0..<Int.random(in: words, using: &rng)).map { _ in randomWord() }.joined(separator: " ")
    }

    /// Draws the next frame as bi-planar 4:2:0 full range.
    public func nextFrame() -> Frame {
        advance()
        var words = Set<String>()
        let bgra = makeBuffer(format: kCVPixelFormatType_32BGRA)
        CVPixelBufferLockBaseAddress(bgra, [])
        let context = CGContext(
            data: CVPixelBufferGetBaseAddress(bgra),
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(bgra),
            space: CGColorSpace(name: CGColorSpace.displayP3)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        )!
        // Use a top-left origin with point units, like a real window.
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: scale, y: -scale)

        draw(scene, in: context, words: &words)
        drawChrome(in: context)

        context.saveGState()
        context.scaleBy(x: 1 / scale, y: 1 / scale)
        FrameBarcode.draw(index, in: context, originY: barcodeY)
        context.restoreGState()
        CVPixelBufferUnlockBaseAddress(bgra, [])

        let output = makeBuffer(format: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)
        VTPixelTransferSessionTransferImage(transfer, from: bgra, to: output)

        defer { index += 1 }
        return Frame(
            pixelBuffer: output,
            fullColorBuffer: bgra,
            index: index,
            scene: scene.rawValue,
            isSceneChange: sceneChanged,
            words: words
        )
    }

    private var sceneChanged = false

    private func advance() {
        ticksUntilSwitch -= 1
        sceneChanged = false
        if ticksUntilSwitch <= 0 {
            let next = Scene.allCases.randomElement(using: &rng)!
            sceneChanged = next != scene
            scene = next
            ticksUntilSwitch = Int.random(in: 20...90, using: &rng)
        }
    }

    private func makeBuffer(format: OSType) -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let attributes: [CFString: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey: [String: Any](),
            kCVPixelBufferMetalCompatibilityKey: true,
        ]
        CVPixelBufferCreate(kCFAllocatorDefault, width, height, format, attributes as CFDictionary, &buffer)
        return buffer!
    }

    private var pointSize: CGSize {
        CGSize(width: CGFloat(width) / scale, height: CGFloat(height) / scale)
    }

    // MARK: Drawing

    private func drawChrome(in context: CGContext) {
        // A menu bar and a static row of bright squares, like a dock.
        context.setFillColor(gray: 0.13, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: pointSize.width, height: 24))
        let colors: [(CGFloat, CGFloat, CGFloat)] = [
            (0.9, 0.3, 0.2), (0.2, 0.6, 0.9), (0.3, 0.8, 0.4), (0.95, 0.7, 0.2), (0.6, 0.4, 0.9),
        ]
        for (i, color) in colors.enumerated() {
            context.setFillColor(red: color.0, green: color.1, blue: color.2, alpha: 1)
            context.fill(CGRect(
                x: pointSize.width / 2 - 150 + CGFloat(i) * 60,
                y: pointSize.height - 56,
                width: 48,
                height: 48
            ))
        }
    }

    private func draw(_ scene: Scene, in context: CGContext, words: inout Set<String>) {
        switch scene {
        case .editor: drawEditor(in: context, words: &words)
        case .article: drawArticle(in: context, video: false, words: &words)
        case .video: drawArticle(in: context, video: true, words: &words)
        case .terminal: drawTerminal(in: context, words: &words)
        case .table: drawTable(in: context, words: &words)
        }
    }

    private func fillBackground(_ context: CGContext, gray: CGFloat) {
        context.setFillColor(gray: gray, alpha: 1)
        context.fill(CGRect(origin: .zero, size: pointSize))
    }

    private func drawLine(
        _ text: String,
        at point: CGPoint,
        font: CTFont,
        gray: CGFloat,
        color: CGColor? = nil,
        in context: CGContext,
        words: inout Set<String>
    ) {
        let attributes: [CFString: Any] = [
            kCTFontAttributeName: font,
            kCTForegroundColorAttributeName: color ?? CGColor(gray: gray, alpha: 1),
        ]
        let attributed = CFAttributedStringCreate(nil, text as CFString, attributes as CFDictionary)!
        let line = CTLineCreateWithAttributedString(attributed)
        context.saveGState()
        // Text draws upward, but this context is flipped.
        context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        context.textPosition = point
        CTLineDraw(line, context)
        context.restoreGState()
        for word in text.split(separator: " ") {
            words.insert(String(word))
        }
    }

    private func drawEditor(in context: CGContext, words: inout Set<String>) {
        fillBackground(context, gray: 0.11)
        let font = CTFontCreateWithName("Menlo" as CFString, 12, nil)

        // Someone typing: most ticks add a word, and every so often a line ends.
        if editorLines.isEmpty {
            editorLines = (0..<20).map { _ in sentence(words: 4...12) }
        }
        if Int.random(in: 0..<8, using: &rng) == 0 {
            editorLines.append(randomWord())
        } else {
            editorLines[editorLines.count - 1] += " " + randomWord()
        }

        let columnX: CGFloat = 240
        let lineHeight: CGFloat = 18
        let visible = Int((pointSize.height - 120) / lineHeight)
        // Syntax colours, some with little contrast in brightness. Storing colour at
        // half resolution could hurt these most.
        let colours = [
            CGColor(red: 0.95, green: 0.45, blue: 0.45, alpha: 1),
            CGColor(red: 0.45, green: 0.75, blue: 0.95, alpha: 1),
            CGColor(red: 0.55, green: 0.85, blue: 0.55, alpha: 1),
            CGColor(red: 0.85, green: 0.65, blue: 0.95, alpha: 1),
            CGColor(red: 0.9, green: 0.9, blue: 0.9, alpha: 1),
        ]
        for (row, line) in editorLines.suffix(visible).enumerated() {
            let colour = colours[row % colours.count]
            drawLine(line, at: CGPoint(x: columnX, y: 50 + CGFloat(row) * lineHeight), font: font, gray: 0.85, color: colour, in: context, words: &words)
        }

        // A static sidebar.
        context.setFillColor(gray: 0.16, alpha: 1)
        context.fill(CGRect(x: 0, y: 24, width: 220, height: pointSize.height))
        let sidebar = CTFontCreateWithName("Helvetica" as CFString, 12, nil)
        for row in 0..<24 {
            var unused = Set<String>()
            let label = vocabulary[(row * 977) % vocabulary.count]
            drawLine(label, at: CGPoint(x: 16, y: 60 + CGFloat(row) * 22), font: sidebar, gray: 0.7, in: context, words: &unused)
            words.insert(label)
        }
    }

    private func drawArticle(in context: CGContext, video: Bool, words: inout Set<String>) {
        fillBackground(context, gray: 0.98)
        let body = CTFontCreateWithName("Georgia" as CFString, 15, nil)

        // Reading: mostly still, with occasional scrolling.
        if Int.random(in: 0..<4, using: &rng) == 0 {
            articleOffset += CGFloat(Int.random(in: 60...300, using: &rng))
        }

        let lineHeight: CGFloat = 24
        let wordsPerLine = 14
        var lines: [String] = []
        for paragraph in articleParagraphs {
            let parts = paragraph.split(separator: " ")
            for start in stride(from: 0, to: parts.count, by: wordsPerLine) {
                lines.append(parts[start..<min(start + wordsPerLine, parts.count)].joined(separator: " "))
            }
            lines.append("")
        }
        let first = Int(articleOffset / lineHeight) % max(lines.count, 1)
        let visible = Int((pointSize.height - 120) / lineHeight)
        let columnX = max(40, pointSize.width / 2 - 340)
        for row in 0..<visible {
            let line = lines[(first + row) % lines.count]
            if line.isEmpty { continue }
            drawLine(line, at: CGPoint(x: columnX, y: 70 + CGFloat(row) * lineHeight), font: body, gray: 0.1, in: context, words: &words)
        }

        // A coloured image beside the text.
        let tint = CGFloat(first % 7) / 7
        context.setFillColor(red: tint, green: 0.5, blue: 1 - tint, alpha: 1)
        context.fill(CGRect(x: pointSize.width - 280, y: 80, width: 240, height: 160))

        if video {
            drawVideoRegion(in: context, rect: CGRect(x: 40, y: 80, width: 320, height: 180))
        }
    }

    /// Stands in for playing video: smooth motion over the whole region on every
    /// tick, which is the hardest thing here to compress.
    private func drawVideoRegion(in context: CGContext, rect: CGRect) {
        let columns = 32, rows = 18
        let cell = CGSize(width: rect.width / CGFloat(columns), height: rect.height / CGFloat(rows))
        let phase = Double(index) * 0.37
        for row in 0..<rows {
            for column in 0..<columns {
                let value = 0.5 + 0.5 * sin(Double(column) * 0.5 + phase) * cos(Double(row) * 0.4 - phase)
                context.setFillColor(red: value, green: 1 - value, blue: 0.5 * value + 0.2, alpha: 1)
                context.fill(CGRect(
                    x: rect.minX + CGFloat(column) * cell.width,
                    y: rect.minY + CGFloat(row) * cell.height,
                    width: cell.width + 1,
                    height: cell.height + 1
                ))
            }
        }
    }

    private func drawTerminal(in context: CGContext, words: inout Set<String>) {
        fillBackground(context, gray: 0.04)
        let font = CTFontCreateWithName("Menlo" as CFString, 12, nil)
        for _ in 0..<Int.random(in: 1...6, using: &rng) {
            terminalLines.append(sentence(words: 3...14))
        }
        let lineHeight: CGFloat = 16
        let visible = Int((pointSize.height - 110) / lineHeight)
        terminalLines = Array(terminalLines.suffix(visible))
        for (row, line) in terminalLines.enumerated() {
            drawLine(line, at: CGPoint(x: 16, y: 44 + CGFloat(row) * lineHeight), font: font, gray: 0.8, in: context, words: &words)
        }
    }

    private func drawTable(in context: CGContext, words: inout Set<String>) {
        fillBackground(context, gray: 1)
        let font = CTFontCreateWithName("Helvetica" as CFString, 12, nil)
        // A few cells change on each tick.
        for _ in 0..<Int.random(in: 0...3, using: &rng) {
            let row = Int.random(in: 0..<tableCells.count, using: &rng)
            let column = Int.random(in: 0..<8, using: &rng)
            tableCells[row][column] = randomWord()
        }
        let columnWidth = (pointSize.width - 40) / 8
        let rowHeight: CGFloat = 26
        for (row, cells) in tableCells.enumerated() {
            let y = 50 + CGFloat(row) * rowHeight
            if y > pointSize.height - 110 { break }
            context.setStrokeColor(gray: 0.85, alpha: 1)
            context.stroke(CGRect(x: 20, y: y - 18, width: pointSize.width - 40, height: rowHeight))
            for (column, text) in cells.enumerated() {
                drawLine(text, at: CGPoint(x: 28 + CGFloat(column) * columnWidth, y: y), font: font, gray: 0.15, in: context, words: &words)
            }
        }
    }
}

/// A small deterministic generator, so a seed always gives the same frames.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed == 0 ? 0x9E37_79B9_7F4A_7C15 : seed
    }

    mutating func next() -> UInt64 {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return state
    }
}
#endif
