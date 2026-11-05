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

/// Receives input for the overlay, then passes it on as actions.
public final class OverlayInputView: NSView {
    public var onAction: ((OverlayAction) -> Void)?
    public var isSearchFocused: () -> Bool = { false }

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
