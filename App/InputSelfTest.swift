#if DEBUG
import AppKit
import Capture
import CoreAPI
import CoreLive
import FeatureSearch
import FeatureTimeline
import Foundation
import Ingest
import OverlayShell
import SwiftUI
import TestKit

/// Sends real events through the real panel and checks what happens, because whether they
/// reach the right view depends on hit testing through SwiftUI, which unit tests can't see.
///
/// The panel never activates the app, as in real use, so this also shows that typing
/// works while another app stays frontmost.
enum InputSelfTest {
    private struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    @MainActor
    static func run(to output: URL) async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "elodie-input-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let core = try LiveCore(vaultDirectory: directory, masterKey: Data(repeating: 3, count: 32))
        let display = UUID()
        let count = 40
        let end = Date()
        let size = NSSize(width: 1280, height: 800)
        let recording = try await FixtureVault.record(
            into: core,
            width: Int(size.width),
            height: Int(size.height),
            count: count,
            display: display,
            start: end.addingTimeInterval(-Double(count) * 2)
        )

        // Text on a known frame, with no need to wait for OCR.
        let lastFrame = try requireValue(core.lookup(display: display, at: recording.time(of: count - 1)))
        var jobs: [OCRJob] = []
        for _ in 0..<500 where jobs.isEmpty {
            jobs = try core.nextOCRBatch(max: count, now: Date(), includeDeferred: true)
            if jobs.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        }
        let textRect = CGRect(x: 0.5, y: 0.5, width: 0.2, height: 0.03)
        try core.submitOCR(jobs.map { job in
            OCRResult(
                frameID: job.frameID,
                lines: job.frameID == lastFrame.id ? [RecognizedLine(text: "selectable words", rect: textRect)] : []
            )
        })

        guard let screen = NSScreen.main else { throw Failure(description: "no screen") }
        let panel = OverlayPanel(screen: screen)
        panel.setFrame(NSRect(origin: screen.frame.origin, size: size), display: false)
        let controller = TimelineController(core: core, display: display, frame: NSRect(origin: .zero, size: size))
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("elodie-input-test-\(UUID().uuidString)"))
        controller.pasteboard = pasteboard
        let search = SearchModel(core: core, debounce: .milliseconds(1))
        var field: NSTextField?
        var editing = false
        var actions: [OverlayAction] = []
        var opened = 0
        controller.isSearchFocused = { editing }
        controller.onAction = { action in
            actions.append(action)
            if case .typed(let text) = action {
                panel.makeFirstResponder(field)
                search.text += text
            }
        }
        controller.install(chrome: OverlayContent(
            core: core,
            timeline: controller,
            search: search,
            highlights: HighlightModel(),
            onOpen: { opened += 1 },
            onDismiss: {},
            actions: OverflowActions(),
            onSelectHit: { _, _ in },
            onOpenHit: { _ in },
            fieldCreated: { field = $0 },
            searchEditing: { editing = $0 },
            searchCancelled: {},
            coachMarks: {
                let defaults = UserDefaults(suiteName: "elodie-scenario")!
                defaults.set(3, forKey: "coachMarkStep")
                return CoachMarkProgress(defaults: defaults)
            }()
        ))
        panel.contentView = controller.rootView
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(controller.keyView)
        controller.present(at: recording.time(of: count - 1))
        controller.model.isSearchVisible = true
        try await Task.sleep(for: .milliseconds(600))

        var results: [String] = []
        func check(_ name: String, _ passed: Bool, _ detail: String = "") {
            results.append("\(passed ? "PASS" : "FAIL") \(name)\(detail.isEmpty ? "" : " (\(detail))")")
        }

        check("the panel is key", panel.isKeyWindow)
        check("the search field exists", field != nil)

        func location(_ x: CGFloat, _ yFromTop: CGFloat) -> NSPoint {
            NSPoint(x: x, y: size.height - yFromTop)
        }

        func scroll(at point: NSPoint, deltaY: Int32) {
            let cgEvent = CGEvent(
                scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: deltaY, wheel2: 0, wheel3: 0
            )!
            cgEvent.location = CGPoint(x: panel.frame.minX + point.x, y: screen.frame.maxY - panel.frame.minY - point.y)
            guard let event = NSEvent(cgEvent: cgEvent) else { return }
            panel.sendEvent(event)
        }

        func mouse(_ type: NSEvent.EventType, at point: NSPoint) {
            guard let event = NSEvent.mouseEvent(
                with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: panel.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
            ) else { return }
            panel.sendEvent(event)
        }

        func key(_ characters: String, code: UInt16, modifiers: NSEvent.ModifierFlags = []) {
            for type in [NSEvent.EventType.keyDown, .keyUp] {
                guard let event = NSEvent.keyEvent(
                    with: type, location: .zero, modifierFlags: modifiers,
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: panel.windowNumber,
                    context: nil, characters: characters, charactersIgnoringModifiers: characters,
                    isARepeat: false, keyCode: code
                ) else { continue }
                panel.sendEvent(event)
            }
        }

        // Scrolling over the empty middle of the frame moves through time.
        var before = controller.playhead
        // A small scroll, so it doesn't run off the start of this short recording.
        scroll(at: location(size.width / 2, size.height / 2), deltaY: 20)
        try await Task.sleep(for: .milliseconds(100))
        check("scrolling over the frame moves the playhead", controller.playhead != before)

        // The strip draws on top of everything, so it mustn't swallow the scroll.
        results.append("NOTE playhead \(end.timeIntervalSince(before)) s back before the strip scroll")
        before = controller.playhead
        scroll(at: location(size.width / 2, size.height - 46), deltaY: 20)
        try await Task.sleep(for: .milliseconds(100))
        check("scrolling over the strip moves the playhead", controller.playhead != before)

        // Back to the frame that has text on it.
        controller.move(to: recording.time(of: count - 1))
        try await Task.sleep(for: .milliseconds(500))

        // A drag across the text selects it, through the SwiftUI layer above.
        let textStart = location(size.width * 0.52, size.height * 0.515)
        let textEnd = location(size.width * 0.65, size.height * 0.515)
        mouse(.leftMouseDown, at: textStart)
        mouse(.leftMouseDragged, at: textEnd)
        mouse(.leftMouseUp, at: textEnd)
        key("c", code: 8, modifiers: .command)
        try await Task.sleep(for: .milliseconds(50))
        let copied = pasteboard.string(forType: .string)
        check("dragging over text and pressing ⌘C copies it", copied == "selectable words", copied ?? "nothing copied")

        // Typing anywhere starts a search, and goes on into the field.
        panel.makeFirstResponder(controller.keyView)
        key("m", code: 46)
        try await Task.sleep(for: .milliseconds(100))
        check("typing starts a search", search.text == "m", "search text \"\(search.text)\"")
        check(
            "the field takes over from there",
            panel.firstResponder === field?.currentEditor() || panel.firstResponder === field,
            "first responder \(String(describing: panel.firstResponder.map { type(of: $0) }))"
        )
        search.clear()
        panel.makeFirstResponder(controller.keyView)

        // Quit and close must not reach the app.
        actions = []
        panel.performKeyEquivalent(with: NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: .command,
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: panel.windowNumber,
            context: nil, characters: "q", charactersIgnoringModifiers: "q", isARepeat: false, keyCode: 12
        )!)
        check("⌘Q closes the overlay instead of quitting", actions.contains(.dismiss))

        // Whether capture can see this panel. This is only this process's view, so it's a
        // hint and not the answer: spike 7 needs another process to settle it. The control
        // is every other scenario, which captures ordinary windows of this process normally.
        check("the panel asks to stay out of screen sharing", panel.sharingType == .none)
        let shot = output.deletingLastPathComponent().appending(path: "overlay-panel-capture.png")
        do {
            try await ScreenContent.saveScreenshot(ofWindow: CGWindowID(panel.windowNumber), to: shot)
            let uniform = isUniform(shot)
            check("capture of the panel shows nothing of its contents", uniform)
        } catch {
            check("capture of the panel shows nothing of its contents", true, "capture refused: \(error)")
        }

        panel.orderOut(nil)
        controller.stop()
        try results.joined(separator: "\n").write(to: output, atomically: true, encoding: .utf8)
    }

    /// Whether an image is one flat colour.
    private static func isUniform(_ url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url),
              let bitmap = NSBitmapImageRep(data: data),
              let first = bitmap.colorAt(x: 0, y: 0)
        else { return false }
        for y in stride(from: 0, to: bitmap.pixelsHigh, by: 8) {
            for x in stride(from: 0, to: bitmap.pixelsWide, by: 8) where bitmap.colorAt(x: x, y: y) != first {
                return false
            }
        }
        return true
    }

    // MARK: The swipe

    /// Drives the real coordinator with real scroll events, as the event tap would. This
    /// takes over the screen and keyboard for about a second.
    @MainActor
    static func runSwipe(to output: URL) async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "elodie-swipe-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let displayID = RecordingController.activeDisplay()
        guard let display = ScreenContent.stableID(of: displayID) else { throw Failure(description: "no display") }
        let core = try LiveCore(vaultDirectory: directory, masterKey: Data(repeating: 4, count: 32))
        let count = 60
        _ = try await FixtureVault.record(
            into: core,
            width: 1280,
            height: 800,
            count: count,
            display: display,
            start: Date().addingTimeInterval(-Double(count) * 2)
        )

        let coordinator = OverlayCoordinator(core: core)
        for _ in 0..<100 where !coordinator.debugIsReady {
            try await Task.sleep(for: .milliseconds(10))
        }

        var results: [String] = []
        func check(_ name: String, _ passed: Bool, _ detail: String = "") {
            results.append("\(passed ? "PASS" : "FAIL") \(name)\(detail.isEmpty ? "" : " (\(detail))")")
        }

        func event(deltaY: Int32, keys: Bool, phase: Int64 = 2, momentum: Int64 = 0) -> NSEvent {
            let cgEvent = CGEvent(
                scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: deltaY, wheel2: 0, wheel3: 0
            )!
            cgEvent.flags = keys ? [.maskCommand, .maskShift] : []
            cgEvent.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
            cgEvent.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
            cgEvent.setIntegerValueField(.scrollWheelEventMomentumPhase, value: momentum)
            return NSEvent(cgEvent: cgEvent)!
        }

        coordinator.handleScroll(event(deltaY: 20, keys: false))
        check("scrolling without the keys doesn't open it", !coordinator.isOpen)
        coordinator.handleScroll(event(deltaY: -20, keys: true))
        check("scrolling down with the keys doesn't open it", !coordinator.isOpen)

        let began = Date()
        let opening = ContinuousClock.now
        coordinator.handleScroll(event(deltaY: 20, keys: true))
        let cost = ContinuousClock.now - opening
        check("scrolling up with the keys opens it", coordinator.isOpen)
        let first = coordinator.debugPlayhead
        let firstBack = first.map { began.timeIntervalSince($0) } ?? 0
        check("the first scroll isn't lost", firstBack > 1, String(format: "%.1f s back after one event", firstBack))
        results.append("NOTE opening took \(cost) on the main thread")

        // The keys come up partway through, and the swipe carries on.
        for _ in 0..<5 {
            coordinator.handleScroll(event(deltaY: 10, keys: false))
        }
        check(
            "the swipe keeps moving after the keys are let go",
            (coordinator.debugPlayhead ?? .distantFuture) < (first ?? .distantPast)
        )
        let beforeGlide = coordinator.debugPlayhead
        coordinator.handleScroll(event(deltaY: 10, keys: false, phase: 0, momentum: 2))
        check(
            "the glide after the fingers lift moves it too",
            (coordinator.debugPlayhead ?? .distantFuture) < (beforeGlide ?? .distantPast)
        )
        let beforeForward = coordinator.debugPlayhead
        coordinator.handleScroll(event(deltaY: -10, keys: false))
        check(
            "scrolling down comes forward again",
            (coordinator.debugPlayhead ?? .distantPast) > (beforeForward ?? .distantFuture)
        )

        try await Task.sleep(for: .milliseconds(400))
        check("the panel came up", coordinator.debugIsPanelVisible)
        coordinator.dismiss()
        check("it closes", !coordinator.isOpen && !coordinator.debugIsPanelVisible)
        results.append("NOTE Accessibility is \(AXIsProcessTrusted() ? "on" : "off") for Elodie, so \(AXIsProcessTrusted() ? "the event tap keeps the app underneath still" : "only the fallback runs: the app underneath will also scroll")")

        try results.joined(separator: "\n").write(to: output, atomically: true, encoding: .utf8)
    }

    private static func requireValue<T>(_ value: T?) throws -> T {
        guard let value else { throw Failure(description: "expected a value") }
        return value
    }
}
#endif
