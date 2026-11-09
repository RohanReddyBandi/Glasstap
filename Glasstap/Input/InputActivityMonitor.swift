import AppKit

/// Remembers when the user last pressed a key or clicked the trackpad.
///
/// Keys and trackpad clicks make the same kind of sharp click as a finger on the glass, so
/// taps heard right next to real input are ignored. Glasstap's own synthetic clicks are
/// skipped (they carry `EventPoster.eventTag`).
final class InputActivityMonitor {
    private var monitors: [Any] = []
    private(set) var lastActivity: Double = -.infinity

    func start() {
        guard monitors.isEmpty else { return }
        let mask: NSEvent.EventTypeMask = [
            .keyDown, .keyUp, .flagsChanged,
            .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .otherMouseDown,
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

    /// Whether real input happened within `window` seconds of `time` (host-clock seconds;
    /// `NSEvent.timestamp` uses the same clock).
    func wasActive(near time: Double, within window: Double) -> Bool {
        abs(time - lastActivity) <= window
    }

    private func note(_ event: NSEvent) {
        if event.cgEvent?.getIntegerValueField(.eventSourceUserData) == EventPoster.eventTag { return }
        lastActivity = max(lastActivity, event.timestamp)
    }
}
