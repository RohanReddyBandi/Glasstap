import AppKit

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }

    /// The MacBook's own display. Nil when the lid is closed (clamshell mode).
    static var builtIn: NSScreen? {
        screens.first { screen in
            screen.displayID.map { CGDisplayIsBuiltin($0) != 0 } ?? false
        }
    }

    /// Converts a normalized point on this screen (0...1, origin bottom-left) to Quartz
    /// global coordinates (origin top-left of the primary display), which `CGEvent` uses.
    func quartzPoint(fromNormalized point: CGPoint) -> CGPoint {
        let x = min(frame.minX + point.x * frame.width, frame.maxX - 1)
        let y = min(frame.minY + point.y * frame.height, frame.maxY - 1)
        let primaryTop = NSScreen.screens.first?.frame.maxY ?? frame.maxY
        return CGPoint(x: x, y: primaryTop - y)
    }
}

extension Float {
    /// "-28 dB"
    var dBText: String { String(format: "%.0f dB", self) }
}
