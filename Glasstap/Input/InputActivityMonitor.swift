import AppKit
import QuartzCore

/// Remembers when the user last used the real keyboard, trackpad or mouse.
///
/// - Key presses and clicks sound like a finger on the glass, so mic taps right next to them
///   are ignored.
/// - When the user grabs the trackpad, the hand stops steering the pointer for a moment
///   instead of fighting them for it.
///
/// Glasstap's own synthetic events carry `InputSynthesizer.eventTag` and are skipped.
final class InputActivityMonitor {
    private var monitors: [Any] = []
    private(set) var lastKeyOrClick: Double = -.infinity
    private(set) var lastPointerUse: Double = -.infinity

    /// Glasstap's own pointer moves can echo back without the tag on some event paths;
    /// anything within this window of our own post is treated as ours.
    var ownPointerPost: () -> Double = { -.infinity }

    func start() {
        guard monitors.isEmpty else { return }
        let mask: NSEvent.EventTypeMask = [
            .keyDown, .keyUp, .flagsChanged,
            .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .otherMouseDown,
            .mouseMoved, .leftMouseDragged, .scrollWheel,
        ]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] event in
            self?.note(event)
        }) {
            monitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            self?.note(event)
            return event
        }) {
            monitors.append(local)
        }
    }

    func stop() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
    }

    /// Whether a real key press or click happened within `window` seconds of `time`
    /// (host-clock seconds; `NSEvent.timestamp` uses the same clock).
    func keyOrClick(near time: Double, within window: Double) -> Bool {
        abs(time - lastKeyOrClick) <= window
    }

    func pointerUsed(within window: Double) -> Bool {
        CACurrentMediaTime() - lastPointerUse <= window
    }

    private func note(_ event: NSEvent) {
        if event.cgEvent?.getIntegerValueField(.eventSourceUserData) == InputSynthesizer.eventTag { return }
        switch event.type {
        case .mouseMoved, .leftMouseDragged, .scrollWheel:
            if event.timestamp - ownPointerPost() < 0.05 { return }
            lastPointerUse = max(lastPointerUse, event.timestamp)
        default:
            lastKeyOrClick = max(lastKeyOrClick, event.timestamp)
            if event.type != .keyDown, event.type != .keyUp, event.type != .flagsChanged {
                lastPointerUse = max(lastPointerUse, event.timestamp)
            }
        }
    }
}
