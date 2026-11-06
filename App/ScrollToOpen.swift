import AppKit
import OverlayShell

/// Lets ⌘⇧ and scrolling up move back through time from any app.
///
/// An event tap can stop a scroll before it reaches the app underneath, so nothing behind
/// the timeline moves or zooms. It sees scroll events and nothing else, and never the
/// keyboard. Without Accessibility permission a tap isn't possible, so this falls back to
/// watching scrolls, which still opens the timeline but can't stop them reaching the app.
final class ScrollToOpen: @unchecked Sendable {
    private let onScroll: @MainActor (NSEvent) -> Void
    private let lock = NSLock()
    private var router = ScrollGestureRouter()
    private var overlayOpen = false
    private var tap: CFMachPort?
    private var monitor: Any?

    init(onScroll: @escaping @MainActor (NSEvent) -> Void) {
        self.onScroll = onScroll
    }

    deinit {
        if let monitor { NSEvent.removeMonitor(monitor) }
    }

    /// Whether scrolls can be stopped before they reach the app underneath.
    var isUsingTap: Bool { tap != nil }

    var isOverlayOpen: Bool {
        get { lock.withLock { overlayOpen } }
        set { lock.withLock { overlayOpen = newValue } }
    }

    /// Starts listening in the best way available. Safe to call repeatedly, so a tap can
    /// take over from the fallback once Accessibility is allowed.
    @MainActor
    func start() {
        guard tap == nil else { return }
        if startTap() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
        } else if monitor == nil {
            monitor = NSEvent.addGlobalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                guard let self else { return }
                MainActor.assumeIsolated { self.onScroll(event) }
            }
        }
    }

    private func startTap() -> Bool {
        let mask = CGEventMask(1 << CGEventType.scrollWheel.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, context in
                guard let context else { return Unmanaged.passUnretained(event) }
                let listener = Unmanaged<ScrollToOpen>.fromOpaque(context).takeUnretainedValue()
                return listener.handle(type, event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return false }
        self.tap = tap

        // Its own thread, because every scroll on the system waits for this. If the main
        // thread is busy, that mustn't make other apps stutter.
        nonisolated(unsafe) let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        nonisolated(unsafe) let startingTap = tap
        let thread = Thread {
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
            CGEvent.tapEnable(tap: startingTap, enable: true)
            CFRunLoopRun()
        }
        thread.name = "elodie-scroll-tap"
        thread.qualityOfService = .userInteractive
        thread.start()
        return true
    }

    private func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        let flags = event.flags
        let decision = lock.withLock {
            router.route(
                modifiersHeld: flags.contains(.maskCommand) && flags.contains(.maskShift),
                overlayOpen: overlayOpen,
                deltaY: event.getDoubleValueField(.scrollWheelEventPointDeltaAxis1),
                phase: ScrollGestureRouter.Phase(rawValue: event.getIntegerValueField(.scrollWheelEventScrollPhase)) ?? .none,
                momentum: ScrollGestureRouter.Momentum(rawValue: event.getIntegerValueField(.scrollWheelEventMomentumPhase)) ?? .none
            )
        }
        guard decision == .takeOver else { return Unmanaged.passUnretained(event) }
        if let copy = event.copy(), let forwarded = NSEvent(cgEvent: copy) {
            let box = EventBox(event: forwarded)
            let onScroll = self.onScroll
            DispatchQueue.main.async {
                MainActor.assumeIsolated { onScroll(box.event) }
            }
        }
        // Dropping it here is what keeps the app underneath perfectly still.
        return nil
    }

    private struct EventBox: @unchecked Sendable {
        let event: NSEvent
    }
}
