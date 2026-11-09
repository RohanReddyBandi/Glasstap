import Carbon.HIToolbox
import CoreGraphics
import QuartzCore

/// Posts synthetic mouse, scroll and keyboard events system-wide. Needs Accessibility
/// access; without it macOS silently drops the events.
///
/// All positions are Quartz global coordinates (origin top-left of the main display).
final class InputSynthesizer {
    /// Stamped on every event Glasstap posts, so its own events can be told apart from the
    /// user's real keyboard and trackpad. ("GLTP")
    static let eventTag: Int64 = 0x474C_5450

    private let source = CGEventSource(stateID: .hidSystemState)
    private(set) var isMouseDown = false
    private var lastPointer: CGPoint?
    /// When Glasstap last moved the pointer, so the activity monitor can ignore the echo.
    private(set) var lastPointerPost: Double = -.infinity

    // MARK: Mouse

    func movePointer(to point: CGPoint) {
        if let last = lastPointer, abs(last.x - point.x) < 0.5, abs(last.y - point.y) < 0.5 { return }
        postMouse(isMouseDown ? .leftMouseDragged : .mouseMoved, at: point, button: .left)
    }

    func click(at point: CGPoint, count: Int) {
        postMouse(.mouseMoved, at: point, button: .left)
        postMouse(.leftMouseDown, at: point, button: .left, clickCount: count)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.012) { [self] in
            postMouse(.leftMouseUp, at: point, button: .left, clickCount: count)
        }
    }

    func rightClick(at point: CGPoint) {
        postMouse(.mouseMoved, at: point, button: .right)
        postMouse(.rightMouseDown, at: point, button: .right, clickCount: 1)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.012) { [self] in
            postMouse(.rightMouseUp, at: point, button: .right, clickCount: 1)
        }
    }

    func mouseDown(at point: CGPoint) {
        postMouse(.mouseMoved, at: point, button: .left)
        postMouse(.leftMouseDown, at: point, button: .left, clickCount: 1)
        isMouseDown = true
    }

    func drag(to point: CGPoint) {
        guard isMouseDown else { return }
        postMouse(.leftMouseDragged, at: point, button: .left)
    }

    func mouseUp(at point: CGPoint) {
        guard isMouseDown else { return }
        postMouse(.leftMouseUp, at: point, button: .left, clickCount: 1)
        isMouseDown = false
    }

    /// Lets go of a held mouse button, wherever the pointer is.
    func releaseAll() {
        guard isMouseDown else { return }
        let location = CGEvent(source: nil)?.location ?? lastPointer ?? .zero
        mouseUp(at: location)
    }

    // MARK: Scroll

    /// Pixel scroll. `dx`/`dy` follow CGEvent's wheel convention: positive `dy` reveals content
    /// above (the page moves down), positive `dx` reveals content to the left.
    func scroll(dx: Int32, dy: Int32) {
        guard dx != 0 || dy != 0,
              let event = CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2, wheel1: dy, wheel2: dx, wheel3: 0)
        else { return }
        event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        event.setIntegerValueField(.eventSourceUserData, value: Self.eventTag)
        event.post(tap: .cghidEventTap)
    }

    // MARK: Keyboard

    /// Swipes act like the trackpad's Mission Control gestures: content follows the hand, so
    /// swiping left moves to the Space on the right.
    func perform(_ swipe: SwipeDirection) {
        let arrow: Int
        switch swipe {
        case .left: arrow = kVK_RightArrow
        case .right: arrow = kVK_LeftArrow
        case .up: arrow = kVK_UpArrow      // Mission Control
        case .down: arrow = kVK_DownArrow  // App Exposé
        }
        // Arrow keys carry the function and keypad flags on real keyboards. Mission Control's
        // shortcuts don't fire without them.
        press(CGKeyCode(arrow), flags: [.maskControl, .maskSecondaryFn, .maskNumericPad])
    }

    /// ⌘+ or ⌘−, the zoom shortcut nearly every Mac app supports. (macOS has no public API for
    /// posting a real pinch gesture.)
    func zoom(_ steps: Int) {
        let key = steps > 0 ? kVK_ANSI_Equal : kVK_ANSI_Minus
        for _ in 0..<abs(steps) {
            press(CGKeyCode(key), flags: .maskCommand)
        }
    }

    private func press(_ key: CGKeyCode, flags: CGEventFlags) {
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: down) else { continue }
            event.flags = flags
            event.setIntegerValueField(.eventSourceUserData, value: Self.eventTag)
            event.post(tap: .cghidEventTap)
        }
    }

    // MARK: -

    private func postMouse(_ type: CGEventType, at point: CGPoint, button: CGMouseButton, clickCount: Int = 0) {
        guard let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: button) else { return }
        if clickCount > 0 {
            event.setIntegerValueField(.mouseEventClickState, value: Int64(clickCount))
        }
        event.setIntegerValueField(.eventSourceUserData, value: Self.eventTag)
        event.post(tap: .cghidEventTap)
        lastPointer = point
        lastPointerPost = CACurrentMediaTime()
    }
}

/// Smooths scrolling. The camera reports hand movement 30 times a second; posting those as
/// 30 big jumps looks choppy on a 120 Hz screen, so each step is spread over the next frame,
/// and a fling keeps gliding with friction after the fingers let go.
final class ScrollAnimator {
    /// Scroll deltas in CGEvent's wheel convention (see `InputSynthesizer.scroll`).
    var post: (_ dx: Int32, _ dy: Int32) -> Void = { _, _ in }

    private var pending = CGVector.zero
    private var velocity = CGVector.zero
    private var remainder = CGVector.zero
    private var timer: Timer?
    private var lastTick: Double = 0

    private static let friction = 3.5          // per second
    private static let maxFlingSpeed: CGFloat = 6000
    private static let minSpeed: CGFloat = 25

    func add(_ delta: CGVector) {
        pending.dx += delta.dx
        pending.dy += delta.dy
        velocity = .zero
        start()
    }

    func fling(_ v: CGVector) {
        let speed = hypot(v.dx, v.dy)
        guard speed > Self.minSpeed * 4 else { return }
        let scale = min(1, Self.maxFlingSpeed / speed)
        velocity = CGVector(dx: v.dx * scale, dy: v.dy * scale)
        start()
    }

    func stop() {
        pending = .zero
        velocity = .zero
        remainder = .zero
        timer?.invalidate()
        timer = nil
    }

    private func start() {
        guard timer == nil else { return }
        lastTick = CACurrentMediaTime()
        let timer = Timer(timeInterval: 1.0 / 120.0, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func tick() {
        let now = CACurrentMediaTime()
        let dt = min(now - lastTick, 0.05)
        lastTick = now

        let share = CGFloat(min(1, dt / (1.0 / 30.0)))
        var step = CGVector(dx: pending.dx * share, dy: pending.dy * share)
        pending.dx -= step.dx
        pending.dy -= step.dy

        step.dx += velocity.dx * dt
        step.dy += velocity.dy * dt
        let decay = CGFloat(exp(-Self.friction * dt))
        velocity = CGVector(dx: velocity.dx * decay, dy: velocity.dy * decay)
        if hypot(velocity.dx, velocity.dy) < Self.minSpeed { velocity = .zero }

        // Content-follows-hand (y up) to wheel deltas: content moving up means scrolling down.
        remainder.dx += step.dx
        remainder.dy += -step.dy
        let dx = Int32(remainder.dx.rounded(.towardZero))
        let dy = Int32(remainder.dy.rounded(.towardZero))
        remainder.dx -= CGFloat(dx)
        remainder.dy -= CGFloat(dy)
        post(dx, dy)

        if abs(pending.dx) < 0.5, abs(pending.dy) < 0.5, velocity == .zero {
            stop()
        }
    }
}
