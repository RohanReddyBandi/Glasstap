import AppKit
import SwiftUI

/// A transparent, click-through window over the whole built-in display. It shows:
/// - a glowing border while touch mode is on (the "it's active" indicator),
/// - the cursor ring, which closes in as your fingers pinch and changes shape for drags and
///   scrolls,
/// - a ripple on every click,
/// - short toasts for touch mode on/off, swipes and zoom.
@MainActor
final class OverlayController {
    enum PulseStyle {
        case primary, secondary
    }

    var showsCursor = true {
        didSet { view.showsCursor = showsCursor }
    }

    private var window: OverlayWindow?
    private let view = OverlayView(frame: .zero)
    private var hideWork: DispatchWorkItem?

    func show(on screen: NSScreen) {
        hideWork?.cancel()
        hideWork = nil
        let window = self.window ?? makeWindow()
        self.window = window
        window.setFrame(screen.frame, display: false)
        view.topInset = max(screen.safeAreaInsets.top, NSStatusBar.system.thickness)
        view.setActive(true)
        window.orderFrontRegardless()
    }

    /// Fades the border and cursor now, and takes the window away after `delay` (long enough
    /// for a toast to finish).
    func hide(after delay: TimeInterval) {
        view.setActive(false)
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.window?.orderOut(nil) }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// Nil hides the ring. `stale` dims it: the hand has left the camera's view.
    func updateCursor(_ feedback: CursorFeedback?, stale: Bool) {
        view.updateCursor(feedback, stale: stale)
    }

    func pulse(at point: CGPoint, style: PulseStyle) {
        view.pulse(at: point, color: style == .primary ? .controlAccentColor : .systemOrange)
    }

    func toast(_ text: String, symbol: String) {
        view.showToast(text, symbol: symbol)
    }

    private func makeWindow() -> OverlayWindow {
        let window = OverlayWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.level = .screenSaver
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        window.isReleasedWhenClosed = false
        view.autoresizingMask = [.width, .height]
        window.contentView = view
        return window
    }
}

final class OverlayWindow: NSWindow {
    // Borderless windows still get nudged below the menu bar; this one has to cover it.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class OverlayView: NSView {
    var showsCursor = true {
        didSet { if !showsCursor { setRingVisible(false) } }
    }
    var topInset: CGFloat = 32 {
        didSet { needsLayout = true }
    }

    private let border = CAShapeLayer()
    private let ring = CALayer()
    private let ringCenter = CALayer()
    private let toastHost = NSHostingView(rootView: ToastView(text: "", symbol: "hand.pinch.fill"))
    private var ringVisible = false
    private var toastWork: DispatchWorkItem?

    private static let cornerRadius: CGFloat = 12

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        configureLayers()
        toastHost.alphaValue = 0
        addSubview(toastHost)
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        border.frame = bounds
        border.path = CGPath(
            roundedRect: bounds.insetBy(dx: 1.5, dy: 1.5),
            cornerWidth: Self.cornerRadius, cornerHeight: Self.cornerRadius, transform: nil
        )
        CATransaction.commit()
        layoutToast()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        let scale = window?.backingScaleFactor ?? 2
        [border, ring, ringCenter].forEach { $0.contentsScale = scale }
    }

    func setActive(_ active: Bool) {
        border.opacity = active ? 1 : 0
        if !active { setRingVisible(false) }
    }

    func updateCursor(_ feedback: CursorFeedback?, stale: Bool) {
        guard showsCursor, let feedback else {
            setRingVisible(false)
            return
        }
        let accent = NSColor.controlAccentColor
        let progress = CGFloat(feedback.pinchProgress)

        // Hovering: the ring closes in as the fingers come together, like a button being
        // pressed. The other states change its shape so you can tell what a pinch is doing.
        var size = CGSize(width: 34 - 18 * progress, height: 34 - 18 * progress)
        var fill = NSColor.white.withAlphaComponent(0.14 + 0.3 * progress)
        var stroke = NSColor.white.withAlphaComponent(0.92)
        var showCenter = true
        switch feedback.state {
        case .hover:
            break
        case .paused:
            // Open hand: the cursor holds still. A faint, hollow ring says "not steering".
            size = CGSize(width: 30, height: 30)
            fill = .clear
            stroke = NSColor.white.withAlphaComponent(0.5)
            showCenter = false
        case .pressed:
            size = CGSize(width: 16, height: 16)
            fill = accent.withAlphaComponent(0.9)
            showCenter = false
        case .dragging:
            size = CGSize(width: 24, height: 24)
            fill = accent.withAlphaComponent(0.9)
            showCenter = false
        case .scrolling:
            size = CGSize(width: 20, height: 40)
            fill = accent.withAlphaComponent(0.55)
            showCenter = false
        case .zooming:
            size = CGSize(width: 34, height: 34)
            fill = .clear
            stroke = accent
        }

        let target = CGPoint(x: feedback.position.x * bounds.width, y: feedback.position.y * bounds.height)
        CATransaction.begin()
        if ringVisible {
            // The camera runs at 30 fps but the display refreshes at up to 120 Hz. Animating
            // each step over one camera frame keeps the ring gliding instead of stepping.
            CATransaction.setAnimationDuration(1.0 / 30.0)
            CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .linear))
        } else {
            CATransaction.setDisableActions(true)
        }
        ring.position = target
        CATransaction.commit()

        CATransaction.begin()
        CATransaction.setAnimationDuration(0.09)
        ring.bounds = CGRect(origin: .zero, size: size)
        ring.cornerRadius = min(size.width, size.height) / 2
        ring.backgroundColor = fill.cgColor
        ring.borderColor = stroke.cgColor
        ringCenter.position = CGPoint(x: size.width / 2, y: size.height / 2)
        ringCenter.opacity = showCenter ? 1 : 0
        ring.opacity = stale ? 0.4 : 1
        CATransaction.commit()
        ringVisible = true
    }

    func pulse(at point: CGPoint, color: NSColor) {
        guard let root = layer else { return }
        let radius: CGFloat = 18
        let ripple = CAShapeLayer()
        ripple.path = CGPath(ellipseIn: CGRect(x: -radius, y: -radius, width: radius * 2, height: radius * 2), transform: nil)
        ripple.position = CGPoint(x: point.x * bounds.width, y: point.y * bounds.height)
        ripple.fillColor = color.withAlphaComponent(0.25).cgColor
        ripple.strokeColor = color.cgColor
        ripple.lineWidth = 2
        ripple.contentsScale = window?.backingScaleFactor ?? 2
        ripple.opacity = 0
        root.addSublayer(ripple)

        let grow = CABasicAnimation(keyPath: "transform.scale")
        grow.fromValue = 0.5
        grow.toValue = 2.2
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.toValue = 0
        let group = CAAnimationGroup()
        group.animations = [grow, fade]
        group.duration = 0.45
        group.timingFunction = CAMediaTimingFunction(name: .easeOut)

        CATransaction.begin()
        CATransaction.setCompletionBlock { ripple.removeFromSuperlayer() }
        ripple.add(group, forKey: "pulse")
        CATransaction.commit()
    }

    func showToast(_ text: String, symbol: String) {
        toastHost.rootView = ToastView(text: text, symbol: symbol)
        layoutToast()
        toastWork?.cancel()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            toastHost.animator().alphaValue = 1
        }
        let work = DispatchWorkItem { [weak self] in
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.35
                self?.toastHost.animator().alphaValue = 0
            }
        }
        toastWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4, execute: work)
    }

    private func configureLayers() {
        guard let root = layer else { return }
        let accent = NSColor.controlAccentColor

        border.fillColor = nil
        border.strokeColor = accent.withAlphaComponent(0.8).cgColor
        border.lineWidth = 3
        border.shadowColor = accent.cgColor
        border.shadowOpacity = 0.9
        border.shadowRadius = 8
        border.shadowOffset = .zero
        border.opacity = 0
        root.addSublayer(border)

        ring.bounds = CGRect(x: 0, y: 0, width: 34, height: 34)
        ring.cornerRadius = 17
        ring.borderWidth = 2
        ring.shadowColor = NSColor.black.cgColor
        ring.shadowOpacity = 0.35
        ring.shadowRadius = 4
        ring.shadowOffset = .zero
        ring.opacity = 0

        ringCenter.bounds = CGRect(x: 0, y: 0, width: 6, height: 6)
        ringCenter.cornerRadius = 3
        ringCenter.backgroundColor = accent.cgColor
        ringCenter.position = CGPoint(x: 17, y: 17)
        ring.addSublayer(ringCenter)
        root.addSublayer(ring)
    }

    private func setRingVisible(_ visible: Bool) {
        guard visible != ringVisible else { return }
        ringVisible = visible
        ring.opacity = visible ? 1 : 0
    }

    private func layoutToast() {
        let size = toastHost.fittingSize
        toastHost.frame = CGRect(
            x: ((bounds.width - size.width) / 2).rounded(),
            y: (bounds.height - topInset - 16 - size.height).rounded(),
            width: size.width,
            height: size.height
        )
    }
}

struct ToastView: View {
    let text: String
    let symbol: String

    var body: some View {
        Label(text, systemImage: symbol)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Capsule().fill(Color.black.opacity(0.75)))
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.18), lineWidth: 1))
            .fixedSize()
    }
}
