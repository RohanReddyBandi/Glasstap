import AppKit
import SwiftUI

/// A transparent, click-through window over the whole built-in display. It shows:
/// - a glowing border while touch mode is on (the "it's active" indicator),
/// - the translucent cursor dot where Glasstap thinks you're pointing,
/// - a ripple on every click it makes,
/// - a short toast when touch mode turns on or off.
@MainActor
final class OverlayController {
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

    /// `point` is normalized on the display (origin bottom-left); nil hides the dot.
    /// `stale` dims it: the hand has left the camera's view but a tap would still use this spot.
    func updatePointer(_ point: CGPoint?, stale: Bool) {
        view.updatePointer(point, stale: stale)
    }

    func pulse(at point: CGPoint) {
        view.pulse(at: point)
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
        didSet { if !showsCursor { setDotVisible(false) } }
    }
    var topInset: CGFloat = 32 {
        didSet { needsLayout = true }
    }

    private let border = CAShapeLayer()
    private let dot = CALayer()
    private let dotCenter = CALayer()
    private let toastHost = NSHostingView(rootView: ToastView(text: "", symbol: "hand.tap.fill"))
    private var dotVisible = false
    private var toastWork: DispatchWorkItem?

    private static let dotSize: CGFloat = 30
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
        [border, dot, dotCenter].forEach { $0.contentsScale = scale }
    }

    func setActive(_ active: Bool) {
        border.opacity = active ? 1 : 0
        if !active { setDotVisible(false) }
    }

    func updatePointer(_ point: CGPoint?, stale: Bool) {
        guard showsCursor, let point else {
            setDotVisible(false)
            return
        }
        let target = CGPoint(x: point.x * bounds.width, y: point.y * bounds.height)
        CATransaction.begin()
        if dotVisible {
            // The camera runs at 30 fps but the display refreshes at up to 120 Hz. Animating
            // each step over one camera frame keeps the dot gliding instead of stepping.
            CATransaction.setAnimationDuration(1.0 / 30.0)
            CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .linear))
        } else {
            CATransaction.setDisableActions(true)
        }
        dot.position = target
        CATransaction.commit()
        dot.opacity = stale ? 0.4 : 1
        dotVisible = true
    }

    func pulse(at point: CGPoint) {
        guard let root = layer else { return }
        let radius: CGFloat = 18
        let ring = CAShapeLayer()
        ring.path = CGPath(ellipseIn: CGRect(x: -radius, y: -radius, width: radius * 2, height: radius * 2), transform: nil)
        ring.position = CGPoint(x: point.x * bounds.width, y: point.y * bounds.height)
        ring.fillColor = NSColor.controlAccentColor.withAlphaComponent(0.25).cgColor
        ring.strokeColor = NSColor.controlAccentColor.cgColor
        ring.lineWidth = 2
        ring.contentsScale = window?.backingScaleFactor ?? 2
        ring.opacity = 0
        root.addSublayer(ring)

        let grow = CABasicAnimation(keyPath: "transform.scale")
        grow.fromValue = 0.5
        grow.toValue = 2.0
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.toValue = 0
        let group = CAAnimationGroup()
        group.animations = [grow, fade]
        group.duration = 0.45
        group.timingFunction = CAMediaTimingFunction(name: .easeOut)

        CATransaction.begin()
        CATransaction.setCompletionBlock { ring.removeFromSuperlayer() }
        ring.add(group, forKey: "pulse")
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

        let size = Self.dotSize
        dot.bounds = CGRect(x: 0, y: 0, width: size, height: size)
        dot.cornerRadius = size / 2
        dot.backgroundColor = NSColor.white.withAlphaComponent(0.22).cgColor
        dot.borderColor = NSColor.white.withAlphaComponent(0.9).cgColor
        dot.borderWidth = 1.5
        dot.shadowColor = NSColor.black.cgColor
        dot.shadowOpacity = 0.35
        dot.shadowRadius = 4
        dot.shadowOffset = .zero
        dot.opacity = 0

        dotCenter.bounds = CGRect(x: 0, y: 0, width: 6, height: 6)
        dotCenter.cornerRadius = 3
        dotCenter.backgroundColor = accent.cgColor
        dotCenter.position = CGPoint(x: size / 2, y: size / 2)
        dot.addSublayer(dotCenter)
        root.addSublayer(dot)
    }

    private func setDotVisible(_ visible: Bool) {
        guard visible != dotVisible else { return }
        dotVisible = visible
        dot.opacity = visible ? 1 : 0
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
