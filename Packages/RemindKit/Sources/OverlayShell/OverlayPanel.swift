import AppKit

/// The screen-covering window that shows history.
///
/// It's non-activating: the app you were using stays active, so opening causes no
/// Space or stage switch, and Esc returns instantly with focus where it was. It can
/// still become key, so keystrokes reach it.
public final class OverlayPanel: NSPanel {
    public override var canBecomeKey: Bool { true }
    public override var canBecomeMain: Bool { false }

    public init(screen: NSScreen) {
        super.init(
            contentRect: screen.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        Self.configure(self)
        setFrame(screen.frame, display: false)
    }

    /// Exposed so a test can check the settings the overlay depends on.
    static func configure(_ panel: NSPanel) {
        // Above the menu bar, Dock, and status items, but below menus and input-method
        // candidates, so those still appear on top.
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        panel.collectionBehavior = [
            .canJoinAllSpaces,
            .canJoinAllApplications,
            .fullScreenAuxiliary,
            .transient,
            .ignoresCycle,
        ]
        panel.hidesOnDeactivate = false
        panel.isOpaque = true
        panel.hasShadow = false
        panel.backgroundColor = .black
        // Opening has to be instant, with no window animation at all.
        panel.animationBehavior = .none
        // History shouldn't be visible to other apps' screen capture. Spike 7 checks
        // whether this is respected.
        panel.sharingType = .none
        panel.isReleasedWhenClosed = false
        panel.acceptsMouseMovedEvents = true
    }
}
