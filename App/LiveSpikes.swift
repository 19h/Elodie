#if DEBUG
import AppKit
import AVFoundation
import Capture
import CoreAPI
import CoreLive
import CoreVideo
import Darwin
import Foundation
import Ingest
import OverlayShell
import ServiceManagement
import TestKit

/// Live capture checks. Nearly all of them only capture this app's own windows, which needs no
/// permission. The energy measurement photographs the whole display if it has the permission.
///
/// Frames are examined in memory and thrown away, so nothing gets stored. The
/// windows these draw are the only thing they look for.
///
/// Launch through `open`, so macOS treats Elodie as the app asking for permission:
///
///     open -n Elodie.app --args --spike capture --out /path/to/report.txt
enum LiveSpikes {
    private static let report = Report()

    @MainActor
    static func run(arguments: [String]) -> Never {
        func value(after flag: String) -> String? {
            arguments.firstIndex(of: flag).flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil }
        }
        let output = value(after: "--out") ?? NSTemporaryDirectory() + "elodie-spike.txt"
        report.open(path: output)

        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        let name = value(after: "--spike") ?? "capture"
        // These only capture the harness's own windows, which needs no permission.
        let needsPermission = !["capture", "privacy", "energy", "colours", "endtoend", "login-item", "sharing-hold"].contains(name)
        guard !needsPermission || CGPreflightScreenCaptureAccess() else {
            report.line("Screen Recording isn't granted.")
            let granted = CGRequestScreenCaptureAccess()
            report.line("Requested it, and the answer was: \(granted). Grant it in System Settings, then run this again.")
            report.close()
            exit(3)
        }

        Task { @MainActor in
            do {
                switch name {
                case "capture": try await Self.captureChecks(iterations: Int(value(after: "--iterations") ?? "") ?? 1000)
                case "privacy": try await Self.privacyRace(iterations: Int(value(after: "--iterations") ?? "") ?? 1000)
                case "energy": try await Self.energy(seconds: Int(value(after: "--seconds") ?? "") ?? 60)
                case "browsers": try await Self.browserTitles()
                case "endtoend": try await Self.endToEnd()
                case "colours": try await Self.colours()
                case "login-item":
                    let agent = Edition.loginItem
                    switch value(after: "--action") {
                    case "on": try agent.register()
                    case "off": try await agent.unregister()
                    default: break
                    }
                    report.line("login item status: \(agent.status.rawValue) (0 not registered, 1 enabled, 2 needs approval, 3 not found)")
                    report.line("accessibility \(AXIsProcessTrusted()), screen recording \(CGPreflightScreenCaptureAccess()), microphone \(AVCaptureDevice.authorizationStatus(for: .audio).rawValue) (0 not asked, 2 denied, 3 allowed)")
                case "sharing-hold": try await Self.sharingHold()
                case "sharing": try await Self.sharingCheck()
                case "sharing-capture":
                    let seen = try await SharingCheck.look(
                        displayID: CGDirectDisplayID(value(after: "--display") ?? "") ?? CGMainDisplayID(),
                        rect: CGRect(
                            x: Double(value(after: "--x") ?? "") ?? 0,
                            y: Double(value(after: "--y") ?? "") ?? 0,
                            width: Double(value(after: "--w") ?? "") ?? 0,
                            height: Double(value(after: "--h") ?? "") ?? 0
                        ),
                        windowID: CGWindowID(value(after: "--window") ?? "") ?? 0
                    )
                    // The system's own tool too, which doesn't go through this code's capture.
                    let picture = FileManager.default.temporaryDirectory.appending(path: "elodie-sharing-\(UUID().uuidString).png")
                    defer { try? FileManager.default.removeItem(at: picture) }
                    let tool = Process()
                    tool.executableURL = URL(filePath: "/usr/sbin/screencapture")
                    tool.arguments = ["-x", "-D", value(after: "--display-index") ?? "1", picture.path]
                    try tool.run()
                    tool.waitUntilExit()
                    let fromTool = NSImage(contentsOf: picture)?.cgImage(forProposedRect: nil, context: nil, hints: nil).map {
                        SharingCheck.count(in: $0, rect: CGRect(
                            x: Double(value(after: "--x") ?? "") ?? 0,
                            y: Double(value(after: "--y") ?? "") ?? 0,
                            width: Double(value(after: "--w") ?? "") ?? 0,
                            height: Double(value(after: "--h") ?? "") ?? 0
                        ))
                    }
                    report.line("display screenshot \(seen.inScreenshot), display stream \(seen.inStream), listed \(seen.isListed), this window alone \(seen.inWindowCapture.map(String.init) ?? "no picture"), screencapture tool \(fromTool.map(String.init) ?? "no picture")")
                default: report.line("Unknown spike \(name)")
                }
                report.line("FINISHED")
            } catch {
                report.line("FAILED: \(error)")
            }
            report.close()
            exit(0)
        }
        app.run()
        exit(0)
    }

    // MARK: Screen sharing

    /// Spike 7's real question: can another app capture the overlay? A small magenta panel with
    /// the overlay's own window settings goes on screen, and a separate copy of this app
    /// captures the whole display, as screen sharing would, and looks for it. An ordinary
    /// shareable panel goes first, to prove the check would see it if it were there.
    @MainActor
    private static func sharingCheck() async throws {
        guard let screen = NSScreen.main,
              let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
        else { throw CocoaError(.featureUnsupported) }
        let size = NSSize(width: 480, height: 320)
        let origin = NSPoint(x: screen.frame.midX - size.width / 2, y: screen.frame.midY - size.height / 2)
        // From the display's top left, for the other process.
        let rect = CGRect(
            x: origin.x - screen.frame.minX + 40,
            y: screen.frame.maxY - origin.y - size.height + 40,
            width: size.width - 80,
            height: size.height - 80
        )
        for (sharing, label) in [(NSWindow.SharingType.readOnly, "ordinary panel (control)"), (.none, "the overlay's setting")] {
            let panel = OverlayPanel(screen: screen)
            panel.sharingType = sharing
            panel.backgroundColor = NSColor(srgbRed: 1, green: 0, blue: 1, alpha: 1)
            panel.ignoresMouseEvents = true
            panel.setFrame(NSRect(origin: origin, size: size), display: true)
            panel.orderFrontRegardless()
            try await Task.sleep(for: .milliseconds(500))

            let answer = URL(filePath: NSTemporaryDirectory()).appending(path: "elodie-sharing-\(UUID().uuidString).txt")
            defer { try? FileManager.default.removeItem(at: answer) }
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.createsNewApplicationInstance = true
            configuration.activates = false
            configuration.arguments = [
                "--spike", "sharing-capture", "--out", answer.path,
                "--display", "\(number)", "--window", "\(panel.windowNumber)",
                "--display-index", "\((NSScreen.screens.firstIndex(of: screen) ?? 0) + 1)",
                "--x", "\(rect.minX)", "--y", "\(rect.minY)", "--w", "\(rect.width)", "--h", "\(rect.height)",
            ]
            _ = try await NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration)
            var result = "no answer"
            for _ in 0..<120 {
                try await Task.sleep(for: .milliseconds(100))
                let text = (try? String(contentsOf: answer, encoding: .utf8)) ?? ""
                if text.contains("FINISHED") || text.contains("FAILED") {
                    result = text.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "FINISHED", with: "")
                    break
                }
            }
            panel.orderOut(nil)
            report.line("\(label): \(result)")
            try await Task.sleep(for: .milliseconds(300))
        }
    }

    /// Holds up a magenta panel on every display, first ordinary and then with the overlay's
    /// setting, for something outside this app to try capturing. It says when each started.
    @MainActor
    private static func sharingHold() async throws {
        for (sharing, label) in [(NSWindow.SharingType.readOnly, "ordinary"), (.none, "overlay")] {
            let panels = NSScreen.screens.map { screen in
                let panel = OverlayPanel(screen: screen)
                panel.sharingType = sharing
                panel.backgroundColor = NSColor(srgbRed: 1, green: 0, blue: 1, alpha: 1)
                panel.ignoresMouseEvents = true
                panel.setFrame(NSRect(x: screen.frame.midX - 240, y: screen.frame.midY - 160, width: 480, height: 320), display: true)
                panel.orderFrontRegardless()
                return panel
            }
            report.line("\(label) from \(Date().timeIntervalSince1970)")
            try await Task.sleep(for: .seconds(8))
            panels.forEach { $0.orderOut(nil) }
            report.line("\(label) until \(Date().timeIntervalSince1970)")
            try await Task.sleep(for: .seconds(2))
        }
    }

    // MARK: Marker windows

    /// A window the harness draws, so tests never need anything else on screen.
    @MainActor
    private static func makeWindow(title: String, frame: NSRect, color: NSColor) -> NSWindow {
        let window = NSWindow(contentRect: frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.title = title
        window.backgroundColor = color
        window.level = .floating
        window.isReleasedWhenClosed = false
        // Over full-screen apps too, or the marker can't appear there and the race proves nothing.
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        return window
    }

    /// A rectangle in the top right of the main display, in AppKit's bottom-left coordinates.
    @MainActor
    private static func corner(_ offset: CGFloat = 0) -> NSRect {
        let screen = NSScreen.screens.first!.frame
        return NSRect(x: screen.maxX - 420 - offset, y: screen.maxY - 320 - offset, width: 360, height: 220)
    }

    /// Whether a frame contains pixels near this colour, inside `rect` (top-left points).
    private static func count(
        chroma target: (cb: UInt8, cr: UInt8),
        in frame: CapturedFrame,
        rect: CGRect,
        display: CGRect
    ) -> Int {
        let buffer = frame.pixelBuffer
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddressOfPlane(buffer, 1) else { return 0 }
        let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1)
        let width = CVPixelBufferGetWidthOfPlane(buffer, 1)
        let height = CVPixelBufferGetHeightOfPlane(buffer, 1)
        let scaleX = CGFloat(width) / display.width
        let scaleY = CGFloat(height) / display.height
        let bytes = base.assumingMemoryBound(to: UInt8.self)

        let minX = max(0, Int((rect.minX - display.minX) * scaleX))
        let maxX = min(width, Int((rect.maxX - display.minX) * scaleX))
        let minY = max(0, Int((rect.minY - display.minY) * scaleY))
        let maxY = min(height, Int((rect.maxY - display.minY) * scaleY))
        guard minX < maxX, minY < maxY else { return 0 }

        var found = 0
        for y in Swift.stride(from: minY, to: maxY, by: 2) {
            let row = bytes + y * stride
            for x in Swift.stride(from: minX, to: maxX, by: 2) {
                let cb = row[x * 2], cr = row[x * 2 + 1]
                if abs(Int(cb) - Int(target.cb)) < 24, abs(Int(cr) - Int(target.cr)) < 24 {
                    found += 1
                }
            }
        }
        return found
    }

    // MARK: Spike 1: change detection

    /// A word on screen, through real capture, encoding, the encrypted log, OCR, and search,
    /// then back to where it was on screen. It only ever captures its own window, which
    /// needs no permission.
    @MainActor
    private static func endToEnd() async throws {
        report.line("End to end: a word on screen, found by search")
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "elodie-e2e-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let displayID = CGMainDisplayID()
        guard let uuid = ScreenContent.stableID(of: displayID), let screen = NSScreen.screens.first else { return }
        let core = try LiveCore(vaultDirectory: directory, masterKey: Data(repeating: 8, count: 32))
        let letters = Array("abcdefghjkmnpqrstuvwxyz")
        let marker = "elodie" + String((0..<8).map { _ in letters.randomElement()! })

        let frame = NSRect(x: 120, y: screen.frame.height - 420, width: 900, height: 160)
        let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.level = .floating
        window.backgroundColor = .white
        let label = NSTextField(labelWithString: marker)
        label.font = .systemFont(ofSize: 72, weight: .regular)
        label.textColor = .black
        label.frame = NSRect(x: 40, y: 30, width: 820, height: 100)
        window.contentView?.addSubview(label)
        window.orderFrontRegardless()
        try await Task.sleep(for: .milliseconds(300))

        let pipeline = try DisplayPipeline(core: core, displayUUID: uuid) { _ in
            .keep(FrameContext(bundleID: "com.kenansulayman.elodie.endtoend", window: "End to end"))
        }
        let capture = DisplayCapture(
            displayID: displayID,
            queue: pipeline.queue,
            onFrame: { [weak pipeline] frame in pipeline?.ingest(frame) },
            onStop: { reason in report.line("  capture stopped: \(reason)") }
        )
        try capture.start(including: window.windowNumber, interval: 0.25)
        // Long enough for several frames, with a change so they aren't all dropped as the same.
        for tick in 0..<8 {
            window.contentView?.layer?.backgroundColor = NSColor(white: tick.isMultiple(of: 2) ? 1 : 0.97, alpha: 1).cgColor
            window.backgroundColor = NSColor(white: tick.isMultiple(of: 2) ? 1 : 0.97, alpha: 1)
            try await Task.sleep(for: .milliseconds(400))
        }
        report.line("  the newest frame is ready to show at once: \(pipeline.latestFrame != nil)")
        await capture.stop()
        window.orderOut(nil)
        try core.sealAll()
        report.line("  stored \(core.stats().loggedFrames) frames, stats \(pipeline.stats)")

        let worker = OCRWorker(core: core)
        worker.start()
        defer { worker.stop() }
        var found: SearchHit?
        let began = Date()
        while found == nil, Date().timeIntervalSince(began) < 300 {
            if let session = try core.search(marker, facets: SearchFacets(), order: .relevance) {
                found = try session.nextPage().hits.first
            }
            if found == nil { try await Task.sleep(for: .milliseconds(200)) }
        }
        guard let found, let rect = found.rects.first else {
            report.line("  FAIL: \(marker) was never found (\(worker.framesProcessed) frames read)")
            return
        }
        report.line(String(format: "  PASS: found %@ after %.1f s, in %@", marker, Date().timeIntervalSince(began), found.bundleID ?? "?"))

        // Where the word should be, as a fraction of the display, from the top left.
        let expected = CGRect(
            x: frame.minX / screen.frame.width,
            y: (screen.frame.height - frame.maxY) / screen.frame.height,
            width: frame.width / screen.frame.width,
            height: frame.height / screen.frame.height
        )
        let lands = expected.contains(CGPoint(x: rect.midX, y: rect.midY))
        report.line("  \(lands ? "PASS" : "FAIL"): the highlight is where the word was on screen (match \(rect), window \(expected))")
    }

    /// Does a frame look right when the timeline shows it, straight from capture? Captures
    /// patches of known colour, shows that frame the way the timeline does, photographs that,
    /// and compares the two.
    @MainActor
    private static func colours() async throws {
        report.line("Colours: a captured frame, shown the way the timeline shows it")
        let displayID = CGMainDisplayID()
        guard let screen = NSScreen.screens.first?.frame else { return }

        final class Latest: @unchecked Sendable {
            let lock = NSLock()
            var buffer: CVPixelBuffer?
        }
        @MainActor func picture(of window: NSWindow) async throws -> CVPixelBuffer? {
            let latest = Latest()
            let capture = DisplayCapture(
                displayID: displayID,
                queue: DispatchQueue(label: "spike.colours", qos: .userInitiated),
                onFrame: { frame in latest.lock.withLock { latest.buffer = frame.pixelBuffer } },
                onStop: { reason in report.line("  capture stopped: \(reason)") }
            )
            try capture.start(including: window.windowNumber, interval: 0.1)
            try await Task.sleep(for: .milliseconds(600))
            await capture.stop()
            return latest.lock.withLock { latest.buffer }
        }
        // Luma and chroma at a place given as a fraction of the display, from the top left.
        func sample(_ buffer: CVPixelBuffer, at point: CGPoint) -> [Int] {
            CVPixelBufferLockBaseAddress(buffer, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
            let x = Int(point.x * CGFloat(CVPixelBufferGetWidth(buffer)))
            let y = Int(point.y * CGFloat(CVPixelBufferGetHeight(buffer)))
            let luma = CVPixelBufferGetBaseAddressOfPlane(buffer, 0)!.assumingMemoryBound(to: UInt8.self)
            let chroma = CVPixelBufferGetBaseAddressOfPlane(buffer, 1)!.assumingMemoryBound(to: UInt8.self)
            let lumaRow = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
            let chromaRow = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1)
            return [
                Int(luma[y * lumaRow + x]),
                Int(chroma[y / 2 * chromaRow + x / 2 * 2]),
                Int(chroma[y / 2 * chromaRow + x / 2 * 2 + 1]),
            ]
        }

        let patches: [(String, NSColor)] = [
            ("red", NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)),
            ("green", NSColor(srgbRed: 0, green: 1, blue: 0, alpha: 1)),
            ("blue", NSColor(srgbRed: 0, green: 0, blue: 1, alpha: 1)),
            ("magenta", NSColor(srgbRed: 1, green: 0, blue: 1, alpha: 1)),
            ("grey", NSColor(srgbRed: 0.5, green: 0.5, blue: 0.5, alpha: 1)),
            ("skin", NSColor(srgbRed: 0.87, green: 0.67, blue: 0.53, alpha: 1)),
        ]
        let side: CGFloat = 120
        let origin = CGPoint(x: 40, y: 200)
        let source = NSWindow(
            contentRect: NSRect(x: origin.x, y: origin.y, width: side * CGFloat(patches.count), height: side),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        source.level = .floating
        for (index, patch) in patches.enumerated() {
            let view = NSView(frame: NSRect(x: side * CGFloat(index), y: 0, width: side, height: side))
            view.wantsLayer = true
            view.layer?.backgroundColor = patch.1.cgColor
            source.contentView?.addSubview(view)
        }
        source.orderFrontRegardless()
        try await Task.sleep(for: .milliseconds(300))
        guard let captured = try await picture(of: source) else {
            report.line("  FAIL: no picture of the patches")
            return
        }
        source.orderOut(nil)

        // The whole frame, shown small in a window of the display's shape.
        let shownSize = NSSize(width: screen.width / 2, height: screen.height / 2)
        let shownOrigin = CGPoint(x: 40, y: 200)
        let shown = NSWindow(contentRect: NSRect(origin: shownOrigin, size: shownSize), styleMask: [.borderless], backing: .buffered, defer: false)
        shown.level = .floating
        let frameView = FrameLayerView(frame: NSRect(origin: .zero, size: shownSize))
        shown.contentView = frameView
        frameView.show(captured)
        shown.orderFrontRegardless()
        try await Task.sleep(for: .milliseconds(300))
        guard let photographed = try await picture(of: shown) else {
            report.line("  FAIL: no picture of the frame")
            return
        }
        shown.orderOut(nil)

        var worst = 0
        for index in patches.indices {
            let inFrame = CGPoint(
                x: (origin.x + side * (CGFloat(index) + 0.5)) / screen.width,
                y: (screen.height - origin.y - side / 2) / screen.height
            )
            let inPhoto = CGPoint(
                x: (shownOrigin.x + inFrame.x * shownSize.width) / screen.width,
                y: (screen.height - shownOrigin.y - shownSize.height + inFrame.y * shownSize.height) / screen.height
            )
            let before = sample(captured, at: inFrame)
            let after = sample(photographed, at: inPhoto)
            let difference = zip(before, after).map { abs($0 - $1) }.max() ?? 0
            worst = max(worst, difference)
            report.line("  \(patches[index].0): captured \(before), shown \(after)")
        }
        report.line("  \(worst <= 4 ? "PASS" : "FAIL"): largest difference \(worst) of 255")
    }

    /// Do the pictures show every change?
    @MainActor
    private static func captureChecks(iterations: Int) async throws {
        report.line("Spike 1: change detection, \(iterations) scripted changes")
        let displayID = CGMainDisplayID()
        guard let size = DisplayCapture.pixelSize(of: displayID) else { return }
        report.line("  display \(displayID): \(size.width)×\(size.height)")

        final class Tally: @unchecked Sendable {
            let lock = NSLock()
            var frames = 0
            var seen = Set<Int>()
            var format: OSType = 0
            var size = (0, 0)
            var unreadable = 0
            var wentBack = 0
            var newest = 0
            var lastPicture: Date?
            var gaps: [(after: Int, seconds: TimeInterval)] = []
        }
        let tally = Tally()
        let queue = DispatchQueue(label: "spike.capture", qos: .userInitiated)
        let view = CounterView(frame: NSRect(x: 0, y: 0, width: 640, height: 64))
        let window = NSWindow(contentRect: NSRect(x: 40, y: 200, width: 640, height: 64), styleMask: [.borderless], backing: .buffered, defer: false)
        window.level = .floating
        window.contentView = view
        window.orderFrontRegardless()

        // Where the counter ends up on screen, in pixels, read back from each frame.
        let origin = window.frame.origin
        let screen = NSScreen.screens.first!.frame
        let scale = CGFloat(size.width) / screen.width
        let barcodeX = Int(origin.x * scale)
        let barcodeY = Int((screen.height - origin.y - 64) * scale)

        let capture = DisplayCapture(
            displayID: displayID,
            queue: queue,
            onFrame: { frame in
                let value = CounterView.read(frame.pixelBuffer, x: barcodeX, y: barcodeY, scale: scale)
                tally.lock.withLock {
                    tally.frames += 1
                    tally.format = CVPixelBufferGetPixelFormatType(frame.pixelBuffer)
                    tally.size = (CVPixelBufferGetWidth(frame.pixelBuffer), CVPixelBufferGetHeight(frame.pixelBuffer))
                    if let last = tally.lastPicture {
                        tally.gaps.append((tally.newest, frame.capturedAt.timeIntervalSince(last)))
                    }
                    tally.lastPicture = frame.capturedAt
                    guard let value else {
                        tally.unreadable += 1
                        return
                    }
                    tally.seen.insert(value)
                    // A picture showing an older value than the one before would mean a stale buffer.
                    if value < tally.newest { tally.wentBack += 1 }
                    tally.newest = max(tally.newest, value)
                }
            },
            onStop: { reason in report.line("  capture stopped: \(reason)") }
        )
        // Only this window, so nothing else on screen is looked at.
        try capture.start(including: window.windowNumber, interval: 0.02)

        for value in 1...iterations {
            view.value = value
            view.display()
            try await Task.sleep(for: .milliseconds(120))
            if value % 250 == 0 {
                report.line("  \(value) changes made")
            }
        }
        try await Task.sleep(for: .milliseconds(300))

        let (seen, frames, format, frameSize) = tally.lock.withLock {
            (tally.seen, tally.frames, tally.format, tally.size)
        }
        let missed = (1...iterations).filter { !seen.contains($0) }
        report.line("  frames delivered \(frames), pixel format \(fourCC(format)), size \(frameSize.0)×\(frameSize.1)")
        report.line("  changes seen \(iterations - missed.count) of \(iterations), missed \(missed.count)\(missed.isEmpty ? "" : " \(missed.prefix(10))")")
        // Each change shows for 120 ms, so a longer wait between pictures has to lose one.
        let (gaps, unreadable, wentBack) = tally.lock.withLock { (tally.gaps, tally.unreadable, tally.wentBack) }
        let sorted = gaps.map(\.seconds).sorted()
        let long = gaps.filter { $0.seconds > 0.12 }
        let explained = missed.filter { value in long.contains { $0.after + 1 <= value && value <= $0.after + 1 + Int($0.seconds / 0.12) } }
        if let longest = sorted.last {
            report.line(String(format: "  time between pictures: median %.0f ms, p99 %.0f ms, longest %.0f ms, over 120 ms: %d",
                               sorted[sorted.count / 2] * 1000, sorted[sorted.count * 99 / 100] * 1000, longest * 1000, long.count))
        }
        report.line("  missed changes that fall inside such a wait: \(explained.count) of \(missed.count)")
        report.line("  pictures showing an older value than the one before: \(wentBack), unreadable: \(unreadable)")

        await capture.stop()
        window.orderOut(nil)
    }

    // MARK: Spike 2: the privacy race

    /// Opens private windows at random moments, and checks that none reaches a frame that
    /// would be kept. Only this app's own windows are ever in the pictures, so this needs no
    /// permission and sees nothing else.
    @MainActor
    private static func privacyRace(iterations: Int) async throws {
        report.line("Spike 2: exclusion race, \(iterations) private windows")
        let displayID = CGMainDisplayID()
        let display = CGDisplayBounds(displayID)
        let ownPID = ProcessInfo.processInfo.processIdentifier

        // Treat this app as a Chromium browser, so its windows go through the real
        // title rules. With `enforce` off, nothing is hidden, which is the control.
        func makeChooser(enforce: Bool) -> WindowChooser {
            WindowChooser(
                policy: ExclusionPolicy(excludedBundleIDs: [], excludesPrivateWindows: enforce),
                hideOwnWindows: false,
                identify: { pid in
                    pid == ownPID ? AppIdentity(bundleID: "test.browser", family: .chromium)
                        : AppIdentity(bundleID: nil, family: nil)
                }
            )
        }

        // Saturated markers, as chroma, for sRGB colours in Display P3 with the BT.709 matrix
        // in 4:2:0 full range.
        let magenta: (cb: UInt8, cr: UInt8) = (206, 210)
        let green: (cb: UInt8, cr: UInt8) = (55, 68)

        let results = RaceResults()
        let queue = DispatchQueue(label: "spike.privacy", qos: .userInitiated)
        let events = RaceEvents()

        func runRace(
            name: String,
            enforce: Bool,
            opens: Int,
            privateTitle: String,
            lifetimes: ClosedRange<Int> = 250...700
        ) async throws -> RaceResults.Snapshot {
            let chooser = makeChooser(enforce: enforce)
            results.reset()
            let area = corner()
            let topLeftArea = CGRect(x: area.minX, y: display.height - area.maxY, width: area.width, height: area.height)
            let capture = DisplayCapture(
                displayID: displayID,
                queue: queue,
                onFrame: { frame in
                    guard !enforce || chooser.check(captured: frame.windows).isSafe else {
                        results.drop()
                        return
                    }
                    let marked = count(chroma: magenta, in: frame, rect: topLeftArea, display: display)
                    results.allowed(
                        magenta: marked,
                        green: count(chroma: green, in: frame, rect: topLeftArea, display: display)
                    )
                    if enforce, marked > 200 {
                        // Explain the leak: what the picture asked for, compared with what happened.
                        let times = events.snapshot()
                        func ms(_ later: UInt64, _ earlier: UInt64) -> String {
                            var base = mach_timebase_info()
                            mach_timebase_info(&base)
                            let delta = Double(Int64(later) - Int64(earlier)) * Double(base.numer) / Double(base.denom) / 1e6
                            return String(format: "%.0f", delta)
                        }
                        let now = mach_absolute_time()
                        report.line("    LEAK \(name): pixels \(marked), checked \(ms(now, times.opened)) ms after open, \(ms(now, times.closed)) ms after close, marker window listed: \(times.windowID.map { frame.windows.contains($0) } ?? false)")
                    }
                },
                onStop: { reason in report.line("  capture stopped: \(reason)") }
            )
            // Something ordinary stays up throughout, or there'd be no picture to race with
            // while a marker is open.
            let backdrop = makeWindow(title: "Backdrop - Brave", frame: area.insetBy(dx: -30, dy: -30), color: NSColor(srgbRed: 0.2, green: 0.2, blue: 0.8, alpha: 1))
            backdrop.orderFrontRegardless()
            defer { backdrop.orderOut(nil) }
            try await Task.sleep(for: .milliseconds(100))
            try capture.start(interval: 0.033, needsPermission: false) {
                chooser.windowsToCapture(ownedBy: ownPID)
            }

            for index in 0..<opens {
                let onScreen = makeWindow(title: "Marker \(index) - \(privateTitle)", frame: area, color: NSColor(srgbRed: 1, green: 0, blue: 1, alpha: 1))
                onScreen.orderFrontRegardless()
                events.noteOpen(CGWindowID(onScreen.windowNumber))
                try await Task.sleep(for: .milliseconds(Int.random(in: lifetimes)))
                onScreen.orderOut(nil)
                events.noteClose()
                try await Task.sleep(for: .milliseconds(Int.random(in: 20...120)))

                // Now and then an ordinary window, which must come through.
                if index % 5 == 0 {
                    let ordinary = makeWindow(title: "Ordinary \(index) - Brave", frame: area, color: NSColor(srgbRed: 0, green: 1, blue: 0, alpha: 1))
                    ordinary.orderFrontRegardless()
                    try await Task.sleep(for: .milliseconds(200))
                    ordinary.orderOut(nil)
                }
                if index % 200 == 199 {
                    report.line("  \(name): \(index + 1) windows opened")
                }
            }
            await capture.stop()
            return results.snapshot()
        }

        // The detector has to be able to see a leak, or zero leaks means nothing.
        let control = try await runRace(name: "control", enforce: false, opens: 30, privateTitle: "Brave (Private)")
        report.line("  control, with hiding off: \(control.framesWithMagenta) frames with the marker, of \(control.allowedFrames)")
        if control.framesWithMagenta == 0 {
            report.line("  CONTROL FAILED: the detector never saw the marker, so the results below prove nothing")
        }

        // Windows that barely exist, which used to be able to slip between two looks at the list.
        let brief = try await runRace(name: "brief", enforce: true, opens: max(iterations / 10, 10), privateTitle: "Brave (Private)", lifetimes: 20...120)
        report.line("  windows open under 120 ms: marker reached the encoder in \(brief.framesWithMagenta) of \(brief.allowedFrames) allowed frames")

        for (language, title) in [("English", "Brave (Private)"), ("German", "Brave (Privat)")] {
            // Checked again each time, because a result only counts if the marker was visible.
            let again = try await runRace(name: "control", enforce: false, opens: 8, privateTitle: title)
            report.line("  control before \(language): \(again.framesWithMagenta) frames with the marker")
            let result = try await runRace(name: language, enforce: true, opens: iterations / 2, privateTitle: title)
            let total = result.allowedFrames + result.droppedFrames
            report.line("  \(language): marker reached the encoder in \(result.framesWithMagenta) of \(result.allowedFrames) allowed frames")
            report.line("    ordinary window seen in \(result.framesWithGreen) frames, dropped \(result.droppedFrames) of \(total) (\(String(format: "%.1f", 100 * Double(result.droppedFrames) / Double(max(total, 1))))%)")
        }
    }

    // MARK: Spike 1: energy

    /// What capture costs this process and the capture daemon, against not capturing at all.
    /// With the permission on, it photographs the whole display, as recording does. Every
    /// picture is thrown away.
    @MainActor
    private static func energy(seconds: Int) async throws {
        report.line("Spike 1: energy, \(seconds) seconds per mode, at a 2 second interval")
        report.line("  Figures cover Elodie and replayd only. WindowServer's share needs powermetrics.")
        let displayID = CGMainDisplayID()
        let view = CounterView(frame: NSRect(x: 0, y: 0, width: 640, height: 64))
        let window = NSWindow(contentRect: NSRect(x: 40, y: 200, width: 640, height: 64), styleMask: [.borderless], backing: .buffered, defer: false)
        window.level = .floating
        window.contentView = view
        window.orderFrontRegardless()

        func changing() -> Task<Void, Never> {
            Task { @MainActor in
                var value = 0
                while !Task.isCancelled {
                    value += 1
                    view.value = value
                    view.display()
                    try? await Task.sleep(for: .seconds(1))
                }
            }
        }

        // Baseline: nothing capturing.
        let idleTask = changing()
        let baseline = try await measure(seconds: seconds)
        idleTask.cancel()
        report.line("  no capture         \(baseline.description)")

        final class Counter: @unchecked Sendable { var frames = 0 }

        let count = Counter()
        let capture = DisplayCapture(
            displayID: displayID,
            queue: DispatchQueue(label: "spike.energy", qos: .utility),
            onFrame: { _ in count.frames += 1 },
            onStop: { _ in }
        )
        let hasPermission = CGPreflightScreenCaptureAccess()
        if hasPermission {
            let chooser = WindowChooser(policy: ExclusionPolicy(excludedBundleIDs: []))
            try capture.start(interval: 2) { chooser.windowsToCapture() }
        } else {
            try capture.start(including: window.windowNumber, interval: 2)
        }
        let task = changing()
        let measured = try await measure(seconds: seconds)
        task.cancel()
        await capture.stop()
        report.line("  one-off pictures, \(hasPermission ? "whole display" : "one window")  \(measured.description), frames \(count.frames)")
        window.orderOut(nil)
    }

    private struct Usage {
        var energyMillijoules: Double
        var cpuMilliseconds: Double
        var seconds: Double

        var description: String {
            String(format: "%6.1f mW, %5.1f ms CPU per second", energyMillijoules / seconds, cpuMilliseconds / seconds)
        }
    }

    private static func snapshot(pid: pid_t) -> (energy: UInt64, cpu: UInt64)? {
        var info = rusage_info_v6()
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V6, $0)
            }
        }
        guard status == 0 else { return nil }
        return (info.ri_billed_energy, info.ri_user_time + info.ri_system_time)
    }

    private static func pid(named name: String) -> pid_t? {
        let pipe = Pipe()
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/pgrep")
        process.arguments = ["-x", name]
        process.standardOutput = pipe
        guard (try? process.run()) != nil else { return nil }
        process.waitUntilExit()
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(decoding: output, as: UTF8.self).split(separator: "\n").first.flatMap { pid_t($0) }
    }

    private static func measure(seconds: Int) async throws -> Usage {
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        let own = ProcessInfo.processInfo.processIdentifier
        let daemon = pid(named: "replayd")
        let pids = [own] + (daemon.map { [$0] } ?? [])
        let before = pids.compactMap(snapshot(pid:))
        try await Task.sleep(for: .seconds(seconds))
        let after = pids.compactMap(snapshot(pid:))
        var energy: UInt64 = 0
        var cpu: UInt64 = 0
        for (start, end) in zip(before, after) {
            energy += end.energy &- start.energy
            cpu += end.cpu &- start.cpu
        }
        return Usage(
            // Billed energy is in nanojoules, and CPU time in mach ticks.
            energyMillijoules: Double(energy) / 1e6,
            cpuMilliseconds: Double(cpu) * Double(timebase.numer) / Double(timebase.denom) / 1e6,
            seconds: Double(seconds)
        )
    }

    // MARK: Real browsers

    /// Lists browser window titles and how the rules classify them. Open private
    /// windows first. This reads titles only.
    @MainActor
    private static func browserTitles() async throws {
        report.line("Real browser windows now on screen:")
        let inventory = WindowInventory()
        for window in inventory.onScreenWindows() where window.layer == 0 {
            let identity = inventory.identify(window.ownerPID)
            guard let family = identity.family else { continue }
            let isPrivate = PrivateWindowRules.isPrivate(title: window.title, family: family)
            // Page titles can be private, so only the part the browser adds is reported.
            let title = window.title ?? "(no title)"
            let tail = title.split(separator: " - ").last.map(String.init) ?? title
            report.line("  \(identity.bundleID ?? "?") \(family): private = \(isPrivate), ends with \"\(tail.suffix(30))\"")
        }
    }

    private static func fourCC(_ value: OSType) -> String {
        let bytes = [24, 16, 8, 0].map { UInt8((value >> $0) & 0xFF) }
        return String(decoding: bytes, as: UTF8.self)
    }
}

/// Shows a number as a barcode, so the frame that captured it can be read back.
final class CounterView: NSView {
    var value = 0
    nonisolated private static let bits = 16
    nonisolated private static let cell: CGFloat = 40

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.setFill()
        bounds.fill()
        NSColor.white.setFill()
        for bit in 0..<Self.bits where (value >> bit) & 1 == 1 {
            NSRect(x: CGFloat(bit) * Self.cell, y: 0, width: Self.cell, height: bounds.height).fill()
        }
    }

    /// Reads the value from a captured frame's luma plane.
    nonisolated static func read(_ buffer: CVPixelBuffer, x: Int, y: Int, scale: CGFloat) -> Int? {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddressOfPlane(buffer, 0) else { return nil }
        let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        let luma = base.assumingMemoryBound(to: UInt8.self)
        let height = CVPixelBufferGetHeight(buffer)
        let width = CVPixelBufferGetWidth(buffer)
        let row = y + Int(32 * scale)
        guard row < height else { return nil }
        var value = 0
        for bit in 0..<bits {
            let column = x + Int((CGFloat(bit) + 0.5) * cell * scale)
            guard column < width else { return nil }
            let sample = luma[row * stride + column]
            if sample > 170 {
                value |= 1 << bit
            } else if sample > 85 {
                return nil
            }
        }
        return value
    }
}

/// Writes results as they happen, so a crash still leaves them.
final class Report: @unchecked Sendable {
    private let lock = NSLock()
    private var handle: FileHandle?

    func open(path: String) {
        FileManager.default.createFile(atPath: path, contents: nil)
        handle = FileHandle(forWritingAtPath: path)
    }

    func line(_ text: String) {
        lock.withLock {
            try? handle?.write(contentsOf: Data((text + "\n").utf8))
        }
    }

    func close() {
        lock.withLock {
            try? handle?.close()
            handle = nil
        }
    }
}

/// When the marker window last opened and closed, for explaining leaks.
final class RaceEvents: @unchecked Sendable {
    struct Snapshot {
        var opened: UInt64 = 0
        var closed: UInt64 = 0
        var windowID: CGWindowID?
    }

    private let lock = NSLock()
    private var state = Snapshot()

    func noteOpen(_ window: CGWindowID) {
        lock.withLock {
            state.opened = mach_absolute_time()
            state.windowID = window
        }
    }

    func noteClose() {
        lock.withLock { state.closed = mach_absolute_time() }
    }

    func snapshot() -> Snapshot { lock.withLock { state } }
}

final class RaceResults: @unchecked Sendable {
    struct Snapshot {
        var allowedFrames = 0
        var droppedFrames = 0
        var framesWithMagenta = 0
        var framesWithGreen = 0
    }

    private let lock = NSLock()
    private var state = Snapshot()

    func reset() { lock.withLock { state = Snapshot() } }
    func drop() { lock.withLock { state.droppedFrames += 1 } }

    /// Counts a frame as containing a marker past a small number of pixels, so stray
    /// similar colours elsewhere don't register.
    func allowed(magenta: Int, green: Int) {
        lock.withLock {
            state.allowedFrames += 1
            if magenta > 200 { state.framesWithMagenta += 1 }
            if green > 200 { state.framesWithGreen += 1 }
        }
    }

    func snapshot() -> Snapshot { lock.withLock { state } }
}

#endif
