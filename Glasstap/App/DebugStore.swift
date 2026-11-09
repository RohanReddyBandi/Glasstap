import Foundation
import Observation

/// Live numbers and an event log for the debug window and the setup preview.
@MainActor
@Observable
final class DebugStore {
    struct Entry: Identifiable {
        enum Kind {
            case info, click, rejected, warning
        }

        let id = UUID()
        let date = Date()
        let kind: Kind
        let text: String
    }

    private(set) var latestFrame: HandFrame?
    var latestUpdate: TrackingUpdate?
    var gestureState = "–"
    private(set) var cameraFPS: Double = 0
    private(set) var visionMilliseconds: Double = 0
    private(set) var entries: [Entry] = []
    @ObservationIgnored private var lastFrameTime: Double?

    /// Whether a hand is in view right now.
    var handVisible: Bool { latestUpdate?.primary != nil }

    func record(_ frame: HandFrame) {
        if let last = lastFrameTime, frame.time > last {
            let fps = 1 / (frame.time - last)
            cameraFPS = cameraFPS == 0 ? fps : cameraFPS * 0.9 + fps * 0.1
        }
        lastFrameTime = frame.time
        visionMilliseconds = visionMilliseconds == 0
            ? frame.visionMilliseconds
            : visionMilliseconds * 0.9 + frame.visionMilliseconds * 0.1
        latestFrame = frame
    }

    func log(_ kind: Entry.Kind, _ text: String) {
        entries.insert(Entry(kind: kind, text: text), at: 0)
        if entries.count > 60 { entries.removeLast() }
    }
}
