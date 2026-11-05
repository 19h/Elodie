import AppKit

/// Remind's menu bar item, which is its main way in.
@MainActor
final class StatusMenu: NSObject {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private weak var controller: AppController?

    init(controller: AppController) {
        self.controller = controller
        super.init()
        refresh()
    }

    /// Rebuilds the menu, so it always reflects the current state.
    func refresh() {
        guard let controller else { return }
        item.button?.image = glyph(isRecording: !controller.isPaused && controller.problem == nil)
        item.button?.toolTip = controller.problem?.message
            ?? (controller.isPaused ? String(localized: "Remind is paused") : String(localized: "Remind is recording"))

        let menu = NSMenu()
        if let problem = controller.problem {
            let row = NSMenuItem(title: problem.message, action: nil, keyEquivalent: "")
            row.image = NSImage(systemSymbolName: "exclamationmark.triangle", accessibilityDescription: nil)
            menu.addItem(row)
            menu.addItem(.separator())
        }

        menu.addItem(entry("Search Remind…", symbol: "magnifyingglass", action: #selector(search)))
        menu.addItem(entry("Ask Remind…", symbol: "questionmark.bubble", action: #selector(ask)))
        menu.addItem(entry("Daily Recap", symbol: "calendar", action: #selector(recap)))
        menu.addItem(entry("Star moment", symbol: "star", action: #selector(star)))
        menu.addItem(.separator())

        if controller.isPaused {
            menu.addItem(entry("Resume recording", symbol: "record.circle", action: #selector(resume)))
        } else {
            let pause = NSMenuItem(title: String(localized: "Pause recording"), action: nil, keyEquivalent: "")
            pause.image = NSImage(systemSymbolName: "pause.circle", accessibilityDescription: nil)
            let durations = NSMenu()
            durations.addItem(entry("For 15 minutes", action: #selector(pause15)))
            durations.addItem(entry("For 1 hour", action: #selector(pause60)))
            durations.addItem(entry("Until I resume", action: #selector(pauseIndefinitely)))
            pause.submenu = durations
            menu.addItem(pause)
        }

        menu.addItem(.separator())
        menu.addItem(entry("Settings…", symbol: "gearshape", action: #selector(settings), key: ","))
        menu.addItem(.separator())
        menu.addItem(entry("Quit Remind", action: #selector(quit), key: "q"))
        item.menu = menu
    }

    private func entry(
        _ title: String.LocalizationValue,
        symbol: String? = nil,
        action: Selector,
        key: String = ""
    ) -> NSMenuItem {
        let item = NSMenuItem(title: String(localized: title), action: action, keyEquivalent: key)
        item.target = self
        if let symbol {
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        }
        return item
    }

    /// Frames in depth crossed by a playhead, the same idea as the app icon.
    private func glyph(isRecording: Bool) -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 16), flipped: false) { rect in
            NSColor.black.set()
            let back = NSBezierPath(roundedRect: NSRect(x: 5, y: 5, width: 11, height: 9), xRadius: 2, yRadius: 2)
            back.lineWidth = 1.3
            back.stroke()
            let front = NSBezierPath(roundedRect: NSRect(x: 2, y: 2, width: 11, height: 9), xRadius: 2, yRadius: 2)
            if isRecording {
                front.fill()
                NSGraphicsContext.current?.compositingOperation = .destinationOut
                NSBezierPath(rect: NSRect(x: 7, y: 2, width: 1.4, height: 9)).fill()
                NSGraphicsContext.current?.compositingOperation = .sourceOver
            } else {
                front.lineWidth = 1.3
                front.stroke()
            }
            return true
        }
        image.isTemplate = true
        return image
    }

    @objc private func search() { controller?.showSearch() }
    @objc private func ask() { controller?.openAsk() }
    @objc private func recap() { controller?.openRecap() }
    @objc private func star() { controller?.starMoment() }
    @objc private func resume() { controller?.setPaused(false) }
    @objc private func pause15() { controller?.setPaused(true, for: 15 * 60) }
    @objc private func pause60() { controller?.setPaused(true, for: 60 * 60) }
    @objc private func pauseIndefinitely() { controller?.setPaused(true) }
    @objc private func settings() { controller?.openSettings() }
    @objc private func quit() { NSApp.terminate(nil) }
}

/// Opens the timeline when ⌘⇧ is held while scrolling, from any app.
@MainActor
final class ScrollToOpen {
    private var monitor: Any?
    private let open: () -> Void

    init(open: @escaping () -> Void) {
        self.open = open
        monitor = NSEvent.addGlobalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard flags.contains(.command), flags.contains(.shift), abs(event.scrollingDeltaY) > 0.5 else { return }
            MainActor.assumeIsolated { self?.open() }
        }
    }
}
