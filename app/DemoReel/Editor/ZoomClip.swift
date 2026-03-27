import Foundation

/// An editable zoom effect clip on the timeline.
struct ZoomClip: Identifiable, Codable {
    let id: UUID
    var timelineStartMs: UInt64
    var durationMs: UInt64
    var centerX: Double
    var centerY: Double
    var scale: Double

    init(id: UUID = UUID(), timelineStartMs: UInt64, durationMs: UInt64, centerX: Double, centerY: Double, scale: Double) {
        self.id = id
        self.timelineStartMs = timelineStartMs
        self.durationMs = durationMs
        self.centerX = centerX
        self.centerY = centerY
        self.scale = scale
    }

    var timelineEndMs: UInt64 {
        timelineStartMs + durationMs
    }

    var timelineDuration: Double {
        Double(durationMs) / 1000.0
    }
}
