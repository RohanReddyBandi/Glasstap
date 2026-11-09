import CoreGraphics

/// Which gestures are on, and how they feel.
struct GestureSettings: Codable, Equatable, Sendable {
    var click = true
    var drag = true
    var scroll = true
    var rightClick = true
    var zoom = true
    var swipe = true
    /// 0...1. Higher registers a pinch with the fingers further apart.
    var pinchSensitivity: Double = 0.5
    /// Scroll distance per unit of hand movement. 1 = content follows the hand one-to-one.
    var scrollSpeed: Double = 1.0
}

enum SwipeDirection: String, Sendable {
    case left, right, up, down
}

enum GestureAction: Equatable, Sendable {
    /// Positions are normalized on the display: 0...1, origin bottom-left.
    case click(CGPoint)
    case rightClick(CGPoint)
    case dragBegan(CGPoint)
    case dragMoved(CGPoint)
    case dragEnded(CGPoint)
    /// How far the content should move, in screen points (y up). Content follows the hand.
    case scroll(CGVector)
    /// Hand speed at release in points per second, for momentum.
    case scrollEnded(velocity: CGVector)
    /// +1 zoom in, -1 zoom out.
    case zoom(Int)
    case swipe(SwipeDirection)
}

/// What the cursor ring should show.
struct CursorFeedback: Equatable, Sendable {
    enum State: Equatable, Sendable {
        case hover, pressed, dragging, scrolling, zooming
    }

    var position: CGPoint
    var state: State = .hover
    /// 0 with the fingers apart, 1 when pinched.
    var pinchProgress: Double = 0
}

/// One tracked hand, as the gesture engine sees it.
struct HandInput: Sendable {
    var metrics: HandMetrics
    /// Smoothed position on the display, normalized and clamped to the screen.
    var cursor: CGPoint
    /// The same position before clamping. Used for motion, so a scroll or swipe that runs
    /// past the edge of the screen still counts.
    var motion: CGPoint
}

/// Turns hand measurements, frame by frame, into clicks, drags, scrolls, zooms and swipes.
///
/// | Gesture | Action |
/// | --- | --- |
/// | Pinch thumb and index, release | Click (twice quickly: double-click) |
/// | Pinch and move | Scroll, with momentum when you let go |
/// | Pinch, hold still, then move | Drag |
/// | Pinch thumb and middle finger | Right-click |
/// | Pinch with both hands, spread or squeeze | Zoom in or out |
/// | Open hand, quick swipe | Switch Space (left/right), Mission Control (up), App Exposé (down) |
struct GestureEngine {
    var settings: GestureSettings {
        didSet { applyThresholds() }
    }
    var screenSize: CGSize

    /// Moving this far (points) during a pinch makes it a scroll instead of a click.
    var moveThreshold: CGFloat = 28
    /// Holding a pinch still this long turns it into a drag.
    var holdDuration: Double = 0.45
    /// Pinches held longer than this without moving don't click on release.
    var maxClickDuration: Double = 1.5
    /// A swipe has to cover `swipeDistance` of the screen within this many seconds.
    var swipeWindow: Double = 0.3
    var swipeDistance: CGFloat = 0.3
    var swipeCooldown: Double = 1.0
    /// Spreading or squeezing the hands by this factor zooms one step.
    var zoomStep: CGFloat = 1.25
    /// After the hand has been gone this long, whatever it was doing ends.
    var lostAfter: Double = 0.25

    private var indexPinch = PinchDetector()
    private var middlePinch = PinchDetector()
    private var otherPinch = PinchDetector()
    private var history: [Sample] = []
    private var phase = Phase.idle
    private var waitingForRelease = false
    private var lastSwipe = -Double.infinity
    private var lastSeen: Double?

    private struct Sample {
        var time: Double
        var cursor: CGPoint
        var motion: CGPoint
        var openPalm: Bool
    }

    private enum Phase {
        case idle
        case press(Press)
        case zoom(baseline: CGFloat)
    }

    private struct Press {
        enum Mode { case pending, scrolling, dragging }

        var began: Double
        var origin: CGPoint
        var originMotion: CGPoint
        var mode = Mode.pending
        var lastMotion: CGPoint
        var lastCursor: CGPoint
        var lastTime: Double
        var velocity = CGVector.zero
        /// Moved, but neither scrolling nor dragging is enabled: release does nothing.
        var cancelled = false
    }

    init(settings: GestureSettings = GestureSettings(), screenSize: CGSize) {
        self.settings = settings
        self.screenSize = screenSize
        applyThresholds()
    }

    /// Whether a drag or scroll is in progress (for deciding where the pointer goes).
    var isPressing: Bool {
        if case .press = phase { return true }
        return false
    }

    /// Ends whatever is in progress (a drag is released, a scroll stops).
    mutating func reset() -> [GestureAction] {
        let actions = endCurrent(withMomentum: false)
        indexPinch.reset()
        middlePinch.reset()
        otherPinch.reset()
        history.removeAll()
        waitingForRelease = false
        lastSeen = nil
        return actions
    }

    /// Feed one camera frame. `primary` drives the cursor; `secondary` is the other hand,
    /// used only for two-hand zoom. Returns the actions to perform, and the cursor to draw
    /// (nil when no hand is in view).
    mutating func update(time: Double, primary: HandInput?, secondary: HandInput?) -> (actions: [GestureAction], feedback: CursorFeedback?) {
        guard let primary else {
            var actions: [GestureAction] = []
            if let seen = lastSeen, time - seen > lostAfter {
                actions = reset()
            }
            return (actions, nil)
        }
        lastSeen = time

        var actions: [GestureAction] = []
        history.append(Sample(time: time, cursor: primary.cursor, motion: primary.motion, openPalm: primary.metrics.isOpenPalm))
        history.removeAll { time - $0.time > 0.6 }

        let indexEvent = indexPinch.update(ratio: primary.metrics.indexPinch, time: time)
        let middleEvent = middlePinch.update(ratio: primary.metrics.middlePinch, time: time)
        if let secondary {
            _ = otherPinch.update(ratio: secondary.metrics.indexPinch, time: time)
        } else {
            otherPinch.reset()
        }
        if waitingForRelease, !indexPinch.isPinched, !otherPinch.isPinched {
            waitingForRelease = false
        }

        // Both hands pinched: zoom takes over from a click or scroll in progress.
        if settings.zoom, let secondary, indexPinch.isPinched, otherPinch.isPinched {
            let baseline = distance(primary.motion, secondary.motion)
            switch phase {
            case .idle:
                phase = .zoom(baseline: baseline)
            case .press(let press) where press.mode != .dragging:
                if press.mode == .scrolling { actions.append(.scrollEnded(velocity: .zero)) }
                phase = .zoom(baseline: baseline)
            default:
                break
            }
        }

        switch phase {
        case .zoom(var baseline):
            if let secondary, indexPinch.isPinched, otherPinch.isPinched {
                let spread = distance(primary.motion, secondary.motion)
                if spread > baseline * zoomStep {
                    actions.append(.zoom(1))
                    baseline = spread
                } else if spread < baseline / zoomStep {
                    actions.append(.zoom(-1))
                    baseline = spread
                }
                phase = .zoom(baseline: baseline)
            } else {
                // Don't let the hand that's still pinched click when it lets go.
                phase = .idle
                waitingForRelease = true
            }

        case .idle:
            if case .down(let closingSince)? = indexEvent, !waitingForRelease, settings.click || settings.drag || settings.scroll {
                let origin = sample(before: max(closingSince, time - 0.3)) ?? history[history.count - 1]
                var press = Press(
                    began: time, origin: origin.cursor, originMotion: origin.motion,
                    lastMotion: origin.motion, lastCursor: primary.cursor, lastTime: time
                )
                // With only clicking enabled there's nothing to wait for: click right away.
                if settings.click, !settings.drag, !settings.scroll {
                    actions.append(.click(origin.cursor))
                    press.cancelled = true
                }
                phase = .press(press)
            } else if case .down(let closingSince)? = middleEvent, settings.rightClick, !indexPinch.isPinched,
                      (primary.metrics.indexPinch ?? .greatestFiniteMagnitude) > indexPinch.thresholds.up {
                let origin = sample(before: max(closingSince, time - 0.3)) ?? history[history.count - 1]
                actions.append(.rightClick(origin.cursor))
            } else if settings.swipe, let direction = detectSwipe(at: time) {
                actions.append(.swipe(direction))
            }

        case .press(var press):
            if indexEvent == .up {
                switch press.mode {
                case .pending:
                    if settings.click, !press.cancelled, time - press.began <= maxClickDuration {
                        actions.append(.click(press.origin))
                    }
                case .scrolling:
                    actions.append(.scrollEnded(velocity: press.velocity))
                case .dragging:
                    actions.append(.dragEnded(primary.cursor))
                }
                phase = .idle
            } else {
                advance(&press, hand: primary, time: time, actions: &actions)
                phase = .press(press)
            }
        }

        return (actions, feedback(for: primary))
    }

    // MARK: - Pinch in progress

    private mutating func advance(_ press: inout Press, hand: HandInput, time: Double, actions: inout [GestureAction]) {
        defer {
            press.lastMotion = hand.motion
            press.lastCursor = hand.cursor
            press.lastTime = time
        }
        switch press.mode {
        case .pending:
            guard !press.cancelled else { return }
            if distance(hand.motion, press.originMotion) > moveThreshold {
                if settings.scroll {
                    press.mode = .scrolling
                    // Include the movement it took to cross the threshold, so content
                    // stays under the hand.
                    actions.append(.scroll(scaled(points(hand.motion) - points(press.originMotion))))
                } else if settings.drag {
                    press.mode = .dragging
                    actions.append(.dragBegan(press.origin))
                    actions.append(.dragMoved(hand.cursor))
                } else {
                    press.cancelled = true
                }
            } else if settings.drag, time - press.began >= holdDuration {
                press.mode = .dragging
                actions.append(.dragBegan(press.origin))
            }

        case .scrolling:
            let delta = scaled(points(hand.motion) - points(press.lastMotion))
            if delta.dx != 0 || delta.dy != 0 { actions.append(.scroll(delta)) }
            let dt = max(time - press.lastTime, 1.0 / 120.0)
            let instant = CGVector(dx: delta.dx / dt, dy: delta.dy / dt)
            press.velocity = CGVector(dx: press.velocity.dx * 0.5 + instant.dx * 0.5, dy: press.velocity.dy * 0.5 + instant.dy * 0.5)

        case .dragging:
            if hand.cursor != press.lastCursor { actions.append(.dragMoved(hand.cursor)) }
        }
    }

    private mutating func endCurrent(withMomentum: Bool) -> [GestureAction] {
        defer { phase = .idle }
        guard case .press(let press) = phase else { return [] }
        switch press.mode {
        case .pending: return []
        case .scrolling: return [.scrollEnded(velocity: withMomentum ? press.velocity : .zero)]
        case .dragging: return [.dragEnded(press.lastCursor)]
        }
    }

    // MARK: - Swipe

    private mutating func detectSwipe(at time: Double) -> SwipeDirection? {
        guard time - lastSwipe >= swipeCooldown, !indexPinch.isPinched, !middlePinch.isPinched else { return nil }
        let recent = history.filter { time - $0.time <= swipeWindow }
        guard recent.count >= 4, let first = recent.first, let last = recent.last,
              last.time - first.time >= 0.12, recent.allSatisfy(\.openPalm)
        else { return nil }

        let dx = (last.motion.x - first.motion.x) * screenSize.width
        let dy = (last.motion.y - first.motion.y) * screenSize.height
        var direction: SwipeDirection?
        if abs(dx) >= swipeDistance * screenSize.width, abs(dx) >= 2 * abs(dy) {
            direction = dx > 0 ? .right : .left
        } else if abs(dy) >= swipeDistance * screenSize.height, abs(dy) >= 2 * abs(dx) {
            direction = dy > 0 ? .up : .down
        }
        if direction != nil {
            lastSwipe = time
            history.removeAll()
        }
        return direction
    }

    // MARK: - Helpers

    private func feedback(for hand: HandInput) -> CursorFeedback {
        var feedback = CursorFeedback(
            position: hand.cursor,
            pinchProgress: indexPinch.progress(for: hand.metrics.indexPinch)
        )
        switch phase {
        case .idle:
            break
        case .zoom:
            feedback.state = .zooming
        case .press(let press):
            switch press.mode {
            case .pending:
                feedback.position = press.origin
                feedback.state = .pressed
            case .scrolling:
                feedback.position = press.origin
                feedback.state = .scrolling
            case .dragging:
                feedback.state = .dragging
            }
        }
        return feedback
    }

    private func sample(before time: Double) -> Sample? {
        history.last { $0.time <= time }
    }

    private mutating func applyThresholds() {
        let thresholds = PinchThresholds(sensitivity: settings.pinchSensitivity)
        indexPinch.thresholds = thresholds
        middlePinch.thresholds = thresholds
        otherPinch.thresholds = thresholds
    }

    private func points(_ p: CGPoint) -> CGPoint {
        CGPoint(x: p.x * screenSize.width, y: p.y * screenSize.height)
    }

    private func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        points(a).distance(to: points(b))
    }

    private func scaled(_ v: CGVector) -> CGVector {
        CGVector(dx: v.dx * settings.scrollSpeed, dy: v.dy * settings.scrollSpeed)
    }
}

private func - (a: CGPoint, b: CGPoint) -> CGVector {
    CGVector(dx: a.x - b.x, dy: a.y - b.y)
}
