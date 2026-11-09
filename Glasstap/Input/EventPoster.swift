import CoreGraphics
import Foundation

/// Posts synthetic mouse events system-wide. Needs Accessibility access; without it the
/// events are silently dropped by macOS.
final class EventPoster {
    /// Stamped on every event Glasstap posts, so its own clicks can be told apart from the
    /// user's real keyboard and trackpad activity. ("GLTP")
    static let eventTag: Int64 = 0x474C_5450

    private let source = CGEventSource(stateID: .hidSystemState)

    /// A left click at `point` in Quartz global coordinates (origin top-left of the main
    /// display). `clickCount` 2 or 3 makes it part of a double or triple click.
    func click(at point: CGPoint, clickCount: Int) {
        post(.mouseMoved, at: point, clickCount: 0)
        post(.leftMouseDown, at: point, clickCount: clickCount)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.012) { [self] in
            post(.leftMouseUp, at: point, clickCount: clickCount)
        }
    }

    private func post(_ type: CGEventType, at point: CGPoint, clickCount: Int) {
        guard let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: .left) else { return }
        if clickCount > 0 {
            event.setIntegerValueField(.mouseEventClickState, value: Int64(clickCount))
        }
        event.setIntegerValueField(.eventSourceUserData, value: Self.eventTag)
        event.post(tap: .cghidEventTap)
    }
}
