import AppKit
import SwiftUI

/// The text field for searching.
///
/// This is AppKit because the overlay's panel never activates the app, and SwiftUI's
/// focus handling can't reliably give a field the keyboard there. An `NSTextField` can
/// be made first responder directly, and it handles input methods properly.
public struct SearchField: NSViewRepresentable {
    @Binding var text: String
    let onCancel: () -> Void
    let onEditingChanged: (Bool) -> Void
    let onCreated: (NSTextField) -> Void

    public init(
        text: Binding<String>,
        onCancel: @escaping () -> Void,
        onEditingChanged: @escaping (Bool) -> Void,
        onCreated: @escaping (NSTextField) -> Void
    ) {
        _text = text
        self.onCancel = onCancel
        self.onEditingChanged = onEditingChanged
        self.onCreated = onCreated
    }

    public func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 22, weight: .medium)
        field.textColor = .white
        field.placeholderAttributedString = NSAttributedString(
            string: String(localized: "Search"),
            attributes: [
                .foregroundColor: NSColor.white.withAlphaComponent(0.45),
                .font: NSFont.systemFont(ofSize: 22, weight: .medium),
            ]
        )
        field.delegate = context.coordinator
        field.cell?.lineBreakMode = .byTruncatingTail
        field.cell?.isScrollable = true
        onCreated(field)
        return field
    }

    public func updateNSView(_ field: NSTextField, context: Context) {
        // Writing while an input method is composing would throw the composition away.
        if let editor = field.currentEditor() as? NSTextView, editor.hasMarkedText() {
            return
        }
        if field.stringValue != text {
            field.stringValue = text
        }
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    public final class Coordinator: NSObject, NSTextFieldDelegate {
        private let parent: SearchField

        init(_ parent: SearchField) {
            self.parent = parent
        }

        public func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            // Not until composition finishes: half-formed input isn't a search.
            if let editor = field.currentEditor() as? NSTextView, editor.hasMarkedText() {
                return
            }
            parent.text = field.stringValue
        }

        public func controlTextDidBeginEditing(_ notification: Notification) {
            parent.onEditingChanged(true)
        }

        public func controlTextDidEndEditing(_ notification: Notification) {
            parent.onEditingChanged(false)
        }

        public func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            // With composition under way, Esc belongs to the input method.
            if selector == #selector(NSResponder.cancelOperation(_:)), !textView.hasMarkedText() {
                parent.onCancel()
                return true
            }
            return false
        }
    }
}
