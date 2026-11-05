import AppKit

/// Everything the overlay can be asked to do from input.
public enum OverlayAction: Equatable, Sendable {
    case scroll(ScrollInput)
    case scrollEnded
    case zoom(magnification: Double)
    case stepFrame(forward: Bool)
    case stepRun(forward: Bool)
    case focusSearch
    /// Text typed with no field focused. Starts a search with this text.
    case typed(String)
    case open
    case star
    case copy
    case dismiss
}

/// Turns keys into actions. Kept apart from the view so it can be tested.
public enum OverlayKeyMap {
    private static let escape: UInt16 = 53
    private static let returnKey: UInt16 = 36
    private static let keypadEnter: UInt16 = 76
    private static let left: UInt16 = 123
    private static let right: UInt16 = 124

    public static func action(
        keyCode: UInt16,
        characters: String?,
        modifiers: NSEvent.ModifierFlags,
        isSearchFocused: Bool
    ) -> OverlayAction? {
        let flags = modifiers.intersection(.deviceIndependentFlagsMask)
        switch keyCode {
        case escape:
            return .dismiss
        // `where` binds to one pattern only, so each needs its own.
        case left where !isSearchFocused, right where !isSearchFocused:
            return flags.contains(.option)
                ? .stepRun(forward: keyCode == right)
                : .stepFrame(forward: keyCode == right)
        case returnKey, keypadEnter:
            return isSearchFocused ? nil : .open
        default:
            break
        }
        if flags.contains(.command) {
            switch characters?.lowercased() {
            case "f": return .focusSearch
            // These must never quit the recorder while the overlay's up.
            case "q", "w": return .dismiss
            case "s" where flags.contains(.shift): return .star
            case "c" where !isSearchFocused: return .copy
            default: return nil
            }
        }
        // Anything else that types starts a search.
        guard !isSearchFocused, flags.isDisjoint(with: [.control, .option]),
              let characters, !characters.isEmpty,
              characters.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) && $0.value < 0xF700 })
        else { return nil }
        return .typed(characters)
    }
}

/// What the mouse is doing over the frame, in this view's coordinates.
public enum OverlayMouse {
    case moved(NSPoint)
    case down(NSPoint)
    case dragged(NSPoint, NSEvent)
    case up(NSPoint)
}

/// Receives input for the overlay, then passes it on as actions.
public final class OverlayInputView: NSView {
    public var onAction: ((OverlayAction) -> Void)?
    public var onMouse: ((OverlayMouse) -> Void)?
    public var isSearchFocused: () -> Bool = { false }
    private var tracking: NSTrackingArea?

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        tracking = area
    }

    private func location(_ event: NSEvent) -> NSPoint {
        convert(event.locationInWindow, from: nil)
    }

    public override func mouseMoved(with event: NSEvent) { onMouse?(.moved(location(event))) }
    public override func mouseDown(with event: NSEvent) { onMouse?(.down(location(event))) }
    public override func mouseDragged(with event: NSEvent) { onMouse?(.dragged(location(event), event)) }
    public override func mouseUp(with event: NSEvent) { onMouse?(.up(location(event))) }

    public override var acceptsFirstResponder: Bool { true }
    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    public override func scrollWheel(with event: NSEvent) {
        onAction?(.scroll(ScrollInput(
            deltaX: event.scrollingDeltaX,
            deltaY: event.scrollingDeltaY,
            hasPreciseDeltas: event.hasPreciseScrollingDeltas,
            isMomentum: !event.momentumPhase.isEmpty,
            isFast: event.modifierFlags.contains(.option),
            timestamp: event.timestamp
        )))
        if event.momentumPhase == .ended || (event.phase == .ended && event.momentumPhase.isEmpty) {
            onAction?(.scrollEnded)
        }
    }

    public override func magnify(with event: NSEvent) {
        onAction?(.zoom(magnification: event.magnification))
    }

    public override func keyDown(with event: NSEvent) {
        if let action = OverlayKeyMap.action(
            keyCode: event.keyCode,
            characters: event.characters,
            modifiers: event.modifierFlags,
            isSearchFocused: isSearchFocused()
        ) {
            onAction?(action)
        } else {
            super.keyDown(with: event)
        }
    }

    public override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if let action = OverlayKeyMap.action(
            keyCode: event.keyCode,
            characters: event.charactersIgnoringModifiers,
            modifiers: event.modifierFlags,
            isSearchFocused: isSearchFocused()
        ), event.modifierFlags.contains(.command) {
            onAction?(action)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}
