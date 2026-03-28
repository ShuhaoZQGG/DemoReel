import Foundation

/// An editable zoom effect clip on the timeline.
struct ZoomClip: Identifiable, Codable {
    let id: UUID
    var timelineStartMs: UInt64
    var durationMs: UInt64
    var centerX: Double
    var centerY: Double
    var scale: Double
    var easeInMs: UInt64
    var easeOutMs: UInt64
    var easeEnabled: Bool

    init(id: UUID = UUID(), timelineStartMs: UInt64, durationMs: UInt64, centerX: Double, centerY: Double, scale: Double, easeInMs: UInt64 = 300, easeOutMs: UInt64 = 400, easeEnabled: Bool = false) {
        self.id = id
        self.timelineStartMs = timelineStartMs
        self.durationMs = durationMs
        self.centerX = centerX
        self.centerY = centerY
        self.scale = scale
        self.easeInMs = easeInMs
        self.easeOutMs = easeOutMs
        self.easeEnabled = easeEnabled
    }

    var timelineEndMs: UInt64 {
        timelineStartMs + durationMs
    }

    var timelineDuration: Double {
        Double(durationMs) / 1000.0
    }

    /// Fraction of total width occupied by ease-in (0–1).
    var easeInFraction: Double {
        guard easeEnabled, durationMs > 0 else { return 0 }
        return Double(easeInMs) / Double(durationMs)
    }

    /// Fraction of total width occupied by ease-out (0–1).
    var easeOutFraction: Double {
        guard easeEnabled, durationMs > 0 else { return 0 }
        return Double(easeOutMs) / Double(durationMs)
    }
}
