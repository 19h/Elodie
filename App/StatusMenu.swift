import AppKit
import KeyboardShortcuts

/// Elodie's menu bar item, which is its main way in.
@MainActor
final class StatusMenu: NSObject, NSMenuDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private weak var controller: AppController?

    init(controller: AppController) {
        self.controller = controller
        super.init()
        menu.delegate = self
        menu.autoenablesItems = false
        item.menu = menu
        refresh()
    }

    /// Updates the icon, so it always shows the current state. The menu itself is built
    /// each time it opens.
    func refresh() {
        guard let controller else { return }
        controller.publishRecordingState()
        // This says what's really happening, which is the only reason to look at it. An icon
        // that claims to be recording when it isn't would cost someone days of history.
        let state: GlyphState
        let status: String
        if let problem = controller.problem {
            state = .problem
            status = problem.message
        } else if controller.isPaused {
            state = .paused
            status = String(localized: "Elodie is paused")
        } else if controller.isRecording {
            state = .recording
            status = String(localized: "Elodie is recording")
        } else if !controller.hasFinishedOnboarding {
            state = .paused
            status = String(localized: "Elodie isn't set up yet")
        } else {
            state = .paused
            status = String(localized: "Elodie isn't recording yet")
        }
        item.button?.image = glyph(state, isListening: controller.isTranscribing)
        item.button?.toolTip = controller.isTranscribing
            ? status + " " + String(localized: "Transcribing audio.")
            : status
        item.button?.setAccessibilityLabel(status)
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        build(menu)
    }

    #if DEBUG
    /// Opens and closes the menu as clicks would, for screenshots.
    func openMenu() { item.button?.performClick(nil) }
    func closeMenu() { menu.cancelTracking() }
    #endif

    /// Fills a menu with what's possible right now.
    func build(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let controller else { return }
        if !controller.hasFinishedOnboarding {
            menu.addItem(entry("Finish setting up Elodie…", symbol: "sparkles", action: #selector(finishSetup)))
            menu.addItem(.separator())
            menu.addItem(entry("Quit Elodie", action: #selector(quit), key: "q"))
            return
        }
        if let problem = controller.problem {
            let row = NSMenuItem(title: problem.message, action: nil, keyEquivalent: "")
            setImage("exclamationmark.triangle", on: row)
            row.isEnabled = false
            menu.addItem(row)
            if problem == .permissionMissing {
                menu.addItem(entry("Open Screen Recording settings…", action: #selector(openPermissionSettings)))
                // A new grant only reaches a new process.
                menu.addItem(entry("Reopen Elodie", symbol: "arrow.clockwise", action: #selector(reopen)))
            }
            if problem == .keyMissing {
                menu.addItem(entry("Unlock with recovery key…", symbol: "key", action: #selector(unlock)))
            }
            if problem.canRetry {
                menu.addItem(entry("Try again", symbol: "arrow.clockwise", action: #selector(tryAgain)))
            }
            menu.addItem(.separator())
        }
        if let audioProblem = controller.audioProblem {
            let row = NSMenuItem(title: audioProblem, action: nil, keyEquivalent: "")
            setImage("waveform.slash", on: row)
            row.isEnabled = false
            menu.addItem(row)
            menu.addItem(.separator())
        }
        let hasRecordings = controller.isVaultOpen

        if let meeting = controller.currentMeetingName, !controller.isTranscribing {
            menu.addItem(entry("Transcribe this \(meeting) meeting", symbol: "waveform.badge.mic", action: #selector(toggleTranscribing)))
            menu.addItem(.separator())
        }

        menu.addItem(entry("Search Elodie…", symbol: "magnifyingglass", action: #selector(search), shortcut: .search, enabled: hasRecordings))
        menu.addItem(entry("Ask Elodie…", symbol: "questionmark.bubble", action: #selector(ask), shortcut: .ask, enabled: hasRecordings))
        menu.addItem(.separator())
        menu.addItem(entry("Daily Recap", symbol: "calendar", action: #selector(recap), shortcut: .dailyRecap, enabled: hasRecordings))
        menu.addItem(entry("Transcripts", symbol: "text.quote", action: #selector(transcripts), enabled: hasRecordings))
        menu.addItem(.separator())

        menu.addItem(switchRow(
            "Screen capture",
            symbol: "rectangle.dashed.badge.record",
            isOn: !controller.isPaused
        ) { [weak self] isOn in
            self?.controller?.setPaused(!isOn)
        })
        menu.addItem(switchRow(
            "Audio capture",
            symbol: "waveform",
            isOn: controller.isTranscribing
        ) { [weak self] _ in
            self?.controller?.toggleTranscribing()
        })
        menu.addItem(entry("Star moment", symbol: "star", action: #selector(star), shortcut: .starMoment, enabled: hasRecordings))
        if !controller.isPaused {
            let pause = NSMenuItem(title: String(localized: "Pause for"), action: nil, keyEquivalent: "")
            setImage("pause.circle", on: pause)
            let durations = NSMenu()
            durations.addItem(entry("15 minutes", action: #selector(pause15)))
            durations.addItem(entry("1 hour", action: #selector(pause60)))
            pause.submenu = durations
            menu.addItem(pause)
        }
        menu.addItem(.separator())

        menu.addItem(entry("Forget the last 5 minutes…", symbol: "clock.arrow.circlepath", action: #selector(forget), enabled: hasRecordings))
        menu.addItem(.separator())
        menu.addItem(entry("Settings…", action: #selector(settings), key: ","))
        menu.addItem(.separator())
        menu.addItem(entry("Quit Elodie", action: #selector(quit), key: "q"))
    }

    private func entry(
        _ title: String.LocalizationValue,
        symbol: String? = nil,
        action: Selector,
        key: String = "",
        shortcut: KeyboardShortcuts.Name? = nil,
        enabled: Bool = true
    ) -> NSMenuItem {
        let item = NSMenuItem(title: String(localized: title), action: action, keyEquivalent: key)
        item.target = self
        item.isEnabled = enabled
        if let symbol {
            setImage(symbol, on: item)
        }
        if let shortcut {
            item.setShortcut(for: shortcut)
        }
        return item
    }

    /// A symbol for a menu row. macOS 27 hides menu images unless asked to show them, and
    /// rows with icons are easier to scan in a menu this long.
    private func setImage(_ symbol: String, on item: NSMenuItem) {
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        if #available(macOS 27, *) {
            item.preferredImageVisibility = .visible
        }
    }

    private func switchRow(
        _ title: String.LocalizationValue,
        symbol: String,
        isOn: Bool,
        onChange: @escaping (Bool) -> Void
    ) -> NSMenuItem {
        let item = NSMenuItem()
        item.view = SwitchRowView(title: String(localized: title), symbol: symbol, isOn: isOn, onChange: onChange)
        return item
    }

    private enum GlyphState {
        case recording, paused, problem
    }

    /// Frames in depth crossed by a playhead, the same idea as the app icon. Paused is an
    /// outline, and a problem is an outline struck through.
    private func glyph(_ state: GlyphState, isListening: Bool) -> NSImage {
        let image = NSImage(size: NSSize(width: isListening ? 24 : 18, height: 16), flipped: false) { _ in
            NSColor.black.set()
            let back = NSBezierPath(roundedRect: NSRect(x: 5, y: 5, width: 11, height: 9), xRadius: 2, yRadius: 2)
            back.lineWidth = 1.3
            back.stroke()
            let front = NSBezierPath(roundedRect: NSRect(x: 2, y: 2, width: 11, height: 9), xRadius: 2, yRadius: 2)
            if state == .recording {
                front.fill()
                NSGraphicsContext.current?.compositingOperation = .destinationOut
                NSBezierPath(rect: NSRect(x: 7, y: 2, width: 1.4, height: 9)).fill()
                NSGraphicsContext.current?.compositingOperation = .sourceOver
            } else {
                front.lineWidth = 1.3
                front.stroke()
            }
            if state == .problem {
                let strike = NSBezierPath()
                strike.move(to: NSPoint(x: 1, y: 15))
                strike.line(to: NSPoint(x: 17, y: 1))
                strike.lineWidth = 1.6
                strike.stroke()
            }
            if isListening {
                // Three bars, which is how anyone can tell audio is being heard.
                for (index, height) in [4.0, 8.0, 5.0].enumerated() {
                    NSBezierPath(
                        roundedRect: NSRect(x: 18.5 + Double(index) * 2, y: 8 - height / 2, width: 1.3, height: height),
                        xRadius: 0.6,
                        yRadius: 0.6
                    ).fill()
                }
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
    @objc private func pause15() { controller?.setPaused(true, for: 15 * 60) }
    @objc private func pause60() { controller?.setPaused(true, for: 60 * 60) }
    @objc private func toggleTranscribing() { controller?.toggleTranscribing() }
    @objc private func transcripts() { controller?.openTranscripts() }
    @objc private func finishSetup() { controller?.showOnboarding() }
    @objc private func unlock() { controller?.showRecovery() }
    @objc private func reopen() { controller?.relaunch() }
    @objc private func tryAgain() { controller?.tryAgain() }

    @objc private func openPermissionSettings() {
        controller?.openPermissionSettings()
    }

    @objc private func forget() {
        // It can't be undone, so it asks first.
        let alert = NSAlert()
        alert.messageText = String(localized: "Forget the last 5 minutes?")
        alert.informativeText = String(localized: "This permanently deletes those recordings and their text.")
        alert.addButton(withTitle: String(localized: "Forget"))
        alert.buttons.first?.hasDestructiveAction = true
        alert.addButton(withTitle: String(localized: "Cancel"))
        NSApp.activate()
        if alert.runModal() == .alertFirstButtonReturn {
            controller?.forgetRecent()
        }
    }

    @objc private func settings() { controller?.openSettings() }
    @objc private func quit() { NSApp.terminate(nil) }
}

/// A menu row with a switch, which stays open when flipped so the change is visible.
final class SwitchRowView: NSView {
    init(title: String, symbol: String, isOn: Bool, onChange: @escaping (Bool) -> Void) {
        super.init(frame: NSRect(x: 0, y: 0, width: 280, height: 28))
        // The menu makes this as wide as its widest row, and the switch stays at the right.
        autoresizingMask = [.width]

        let icon = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil) ?? NSImage())
        icon.contentTintColor = .labelColor
        // In line with the icons and titles of ordinary rows, which macOS places itself.
        icon.frame = NSRect(x: 13.5, y: 5, width: 18, height: 18)
        addSubview(icon)

        let label = NSTextField(labelWithString: title)
        label.font = .menuFont(ofSize: 0)
        label.frame = NSRect(x: 36, y: 5, width: 170, height: 18)
        addSubview(label)

        let control = AccentSwitch(title: title, isOn: isOn, onChange: onChange)
        control.autoresizingMask = [.minXMargin]
        control.frame.origin = NSPoint(x: 280 - control.frame.width - 18, y: (28 - control.frame.height) / 2)
        addSubview(control)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Not used") }
}

/// A switch that shows its state in the accent colour. The system's turns grey in a menu,
/// because the app isn't active, which leaves only the knob's position to go on.
private final class AccentSwitch: NSControl {
    private let knob = CALayer()
    private let onChange: (Bool) -> Void
    private var isOn: Bool

    private static let size = NSSize(width: 34, height: 20)

    init(title: String, isOn: Bool, onChange: @escaping (Bool) -> Void) {
        self.isOn = isOn
        self.onChange = onChange
        super.init(frame: NSRect(origin: .zero, size: Self.size))
        wantsLayer = true
        layer?.cornerRadius = Self.size.height / 2
        knob.backgroundColor = NSColor.white.cgColor
        knob.cornerRadius = (Self.size.height - 4) / 2
        knob.shadowOpacity = 0.25
        knob.shadowRadius = 1
        knob.shadowOffset = CGSize(width: 0, height: -0.5)
        layer?.addSublayer(knob)
        setAccessibilityElement(true)
        setAccessibilityRole(.checkBox)
        setAccessibilityLabel(title)
        update(animated: false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Not used") }

    override func mouseDown(with event: NSEvent) {
        isOn.toggle()
        update(animated: true)
        onChange(isOn)
    }

    private func update(animated: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(!animated)
        layer?.backgroundColor = (isOn
            ? NSColor.controlAccentColor
            : NSColor.labelColor.withAlphaComponent(0.2)).cgColor
        let diameter = Self.size.height - 4
        knob.frame = CGRect(
            x: isOn ? Self.size.width - diameter - 2 : 2,
            y: 2,
            width: diameter,
            height: diameter
        )
        CATransaction.commit()
        setAccessibilityValue(isOn)
    }
}
