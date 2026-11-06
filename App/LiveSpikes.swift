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

/// Live capture checks. Spike 2 and the energy measurement need the Screen Recording
/// permission, and the others only capture this app's own windows, which doesn't.
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
        let needsPermission = !["capture", "endtoend", "login-item", "sharing-hold"].contains(name)
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
            .keep(FrameContext(bundleID: "com.kenansulayman.Elodie.endtoend", window: "End to end"))
        }
        let stream = DisplayStream(
            displayID: displayID,
            queue: pipeline.queue,
            onFrame: { [weak pipeline] frame in pipeline?.ingest(frame) },
            onStop: { reason in report.line("  the stream stopped: \(reason)") }
        )
        try await stream.start(including: window.windowNumber, interval: 0.25)
        // Long enough for several frames, with a change so they aren't all dropped as the same.
        for tick in 0..<8 {
            window.contentView?.layer?.backgroundColor = NSColor(white: tick.isMultiple(of: 2) ? 1 : 0.97, alpha: 1).cgColor
            window.backgroundColor = NSColor(white: tick.isMultiple(of: 2) ? 1 : 0.97, alpha: 1)
            try await Task.sleep(for: .milliseconds(400))
        }
        report.line("  the newest frame is ready to show at once: \(pipeline.latestFrame != nil)")
        await stream.stop()
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

    /// Does the stream show every change, and stay quiet when nothing changes?
    @MainActor
    private static func captureChecks(iterations: Int) async throws {
        report.line("Spike 1: change detection, \(iterations) scripted changes")
        let displayID = CGMainDisplayID()
        guard let size = DisplayStream.pixelSize(of: displayID) else { return }
        report.line("  display \(displayID): \(size.width)×\(size.height)")

        final class Tally: @unchecked Sendable {
            let lock = NSLock()
            var frames = 0
            var seen = Set<Int>()
            var dirty = 0
            var format: OSType = 0
            var size = (0, 0)
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

        let stream = DisplayStream(
            displayID: displayID,
            queue: queue,
            onFrame: { frame in
                let value = CounterView.read(frame.pixelBuffer, x: barcodeX, y: barcodeY, scale: scale)
                tally.lock.withLock {
                    tally.frames += 1
                    tally.dirty += frame.dirtyRects.count
                    tally.format = CVPixelBufferGetPixelFormatType(frame.pixelBuffer)
                    tally.size = (CVPixelBufferGetWidth(frame.pixelBuffer), CVPixelBufferGetHeight(frame.pixelBuffer))
                    if let value { tally.seen.insert(value) }
                }
            },
            onStop: { reason in report.line("  the stream stopped: \(reason)") }
        )
        // Only this window, so nothing else on screen is looked at.
        try await stream.start(including: window.windowNumber, interval: 0.02)

        for value in 1...iterations {
            view.value = value
            view.display()
            try await Task.sleep(for: .milliseconds(120))
            if value % 250 == 0 {
                report.line("  \(value) changes made")
            }
        }
        try await Task.sleep(for: .milliseconds(300))

        let (seen, frames, format, frameSize, dirty) = tally.lock.withLock {
            (tally.seen, tally.frames, tally.format, tally.size, tally.dirty)
        }
        let missed = (1...iterations).filter { !seen.contains($0) }
        report.line("  frames delivered \(frames), pixel format \(fourCC(format)), size \(frameSize.0)×\(frameSize.1), dirty rects \(dirty)")
        report.line("  changes seen \(iterations - missed.count) of \(iterations), missed \(missed.count)\(missed.isEmpty ? "" : " \(missed.prefix(10))")")

        // Now nothing changes, and an idle screen should deliver nothing.
        let before = tally.lock.withLock { tally.frames }
        try await Task.sleep(for: .seconds(5))
        let after = tally.lock.withLock { tally.frames }
        report.line("  frames delivered in 5 idle seconds: \(after - before)")
        await stream.stop()
        window.orderOut(nil)
    }

    // MARK: Spike 2: the privacy race

    /// Opens private windows at random moments, and checks that none reaches a frame
    /// the gate allows through.
    @MainActor
    private static func privacyRace(iterations: Int) async throws {
        report.line("Spike 2: exclusion race, \(iterations) private windows")
        let displayID = CGMainDisplayID()
        let display = CGDisplayBounds(displayID)
        let ownPID = ProcessInfo.processInfo.processIdentifier

        // Treat this app as a Chromium browser, so its windows go through the real
        // title rules.
        func makeMonitor() -> ExclusionMonitor {
            ExclusionMonitor(
                policy: ExclusionPolicy(excludedBundleIDs: []),
                hideOwnWindows: false,
                identify: { pid in
                    pid == ownPID ? AppIdentity(bundleID: "test.browser", family: .chromium)
                        : AppIdentity(bundleID: nil, family: nil)
                }
            )
        }

        // Saturated markers, as chroma, for sRGB colours captured in Display P3 with the
        // BT.709 matrix in 4:2:0 full range.
        let magenta: (cb: UInt8, cr: UInt8) = (196, 211)
        let green: (cb: UInt8, cr: UInt8) = (56, 69)

        let results = RaceResults()
        let queue = DispatchQueue(label: "spike.privacy", qos: .userInitiated)
        var lastWindowCheck: Duration = .zero
        let events = RaceEvents()

        func runRace(
            name: String,
            enforce: Bool,
            opens: Int,
            privateTitle: String,
            lifetimes: ClosedRange<Int> = 250...700
        ) async throws -> RaceResults.Snapshot {
            let monitor = makeMonitor()
            results.reset()
            let area = corner()
            let topLeftArea = CGRect(x: area.minX, y: display.height - area.maxY, width: area.width, height: area.height)
            let stream = DisplayStream(
                displayID: displayID,
                queue: queue,
                onFrame: { frame in
                    let check = monitor.check(frameDisplayTime: frame.displayTime)
                    guard !enforce || check.verdict == .allow else {
                        results.drop()
                        return
                    }
                    let marked = count(chroma: magenta, in: frame, rect: topLeftArea, display: display)
                    results.allowed(
                        magenta: marked,
                        green: count(chroma: green, in: frame, rect: topLeftArea, display: display)
                    )
                    if enforce, marked > 200 {
                        // Explain the leak: when this frame was composed, compared with what happened.
                        let gate = monitor.gateState
                        let times = events.snapshot()
                        func ms(_ later: UInt64, _ earlier: UInt64) -> String {
                            var base = mach_timebase_info()
                            mach_timebase_info(&base)
                            let delta = Double(Int64(later) - Int64(earlier)) * Double(base.numer) / Double(base.denom) / 1e6
                            return String(format: "%.0f", delta)
                        }
                        report.line("    LEAK \(name): pixels \(marked), composed \(ms(frame.displayTime, times.opened)) ms after open, \(ms(frame.displayTime, times.closed)) ms after close, \(ms(frame.displayTime, gate.committedAt ?? 0)) ms after commit, checked \(ms(mach_absolute_time(), frame.displayTime)) ms later, filter covers \(gate.committed.count), current window in filter: \(times.windowID.map { gate.committed.contains($0) } ?? false), required now \(check.required.count)")
                    }
                },
                onStop: { reason in report.line("  the stream stopped: \(reason)") }
            )
            try await monitor.start(stream, interval: 0.033)

            var checks = [Duration]()
            let clock = ContinuousClock()
            for index in 0..<opens {
                let started = clock.now
                let onScreen = makeWindow(title: "Marker \(index) - \(privateTitle)", frame: area, color: NSColor(srgbRed: 1, green: 0, blue: 1, alpha: 1))
                onScreen.orderFrontRegardless()
                events.noteOpen(CGWindowID(onScreen.windowNumber))
                checks.append(clock.now - started)
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
            await stream.stop()
            monitor.stop()
            lastWindowCheck = monitor.averageWindowCheck
            return results.snapshot()
        }

        // The detector has to be able to see a leak, or zero leaks means nothing.
        let control = try await runRace(name: "control", enforce: false, opens: 30, privateTitle: "Brave (Private)")
        report.line("  control, with the gate off: \(control.framesWithMagenta) frames with the marker, of \(control.allowedFrames)")
        if control.framesWithMagenta == 0 {
            report.line("  CONTROL FAILED: the detector never saw the marker, so the results below prove nothing")
        }

        // Too short for the watcher to be sure of seeing, so this shows the limit of the
        // guarantee. A window open this briefly can barely draw anything.
        let brief = try await runRace(name: "brief", enforce: true, opens: max(iterations / 10, 10), privateTitle: "Brave (Private)", lifetimes: 20...120)
        report.line("  windows open under 120 ms: marker reached the encoder in \(brief.framesWithMagenta) of \(brief.allowedFrames) allowed frames")

        for (language, title) in [("English", "Brave (Private)"), ("German", "Brave (Privat)")] {
            // Checked again each time, because a result only counts if the marker was visible.
            let again = try await runRace(name: "control", enforce: false, opens: 8, privateTitle: title)
            report.line("  control before \(language): \(again.framesWithMagenta) frames with the marker")
            let result = try await runRace(name: language, enforce: true, opens: iterations / 2, privateTitle: title)
            let total = result.allowedFrames + result.droppedFrames
            report.line("  \(language): marker reached the encoder in \(result.framesWithMagenta) of \(result.allowedFrames) allowed frames")
            report.line("    the watcher took \(lastWindowCheck) per look")
            report.line("    ordinary window seen in \(result.framesWithGreen) frames, dropped \(result.droppedFrames) of \(total) (\(String(format: "%.1f", 100 * Double(result.droppedFrames) / Double(max(total, 1))))%)")
        }
    }

    // MARK: Spike 1: energy

    /// Compares capture approaches by what this process and the capture daemon use.
    @MainActor
    private static func energy(seconds: Int) async throws {
        report.line("Spike 1: energy, \(seconds) seconds per mode, at a 2 second interval")
        report.line("  Figures cover Elodie and replayd only. WindowServer's share needs powermetrics.")
        let displayID = CGMainDisplayID()
        let queue = DispatchQueue(label: "spike.energy", qos: .utility)
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

        let streamCount = Counter()
        let stream = DisplayStream(
            displayID: displayID,
            queue: queue,
            onFrame: { _ in streamCount.frames += 1 },
            onStop: { _ in }
        )
        try await stream.start(excluding: [], interval: 2)
        let streamTask = changing()
        let streaming = try await measure(seconds: seconds)
        streamTask.cancel()
        await stream.stop()
        report.line("  SCStream           \(streaming.description), frames \(streamCount.frames)")

        let shotCount = Counter()
        let shotTask = changing()
        let shots = Task.detached {
            while !Task.isCancelled {
                if (try? await ScreenContent.screenshot(displayID: displayID)) != nil {
                    shotCount.frames += 1
                }
                try? await Task.sleep(for: .seconds(2))
            }
        }
        let shooting = try await measure(seconds: seconds)
        shots.cancel()
        shotTask.cancel()
        report.line("  SCScreenshotManager \(shooting.description), frames \(shotCount.frames)")
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
