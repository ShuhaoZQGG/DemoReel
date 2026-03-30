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
    var easingCurve: String

    init(id: UUID = UUID(), timelineStartMs: UInt64, durationMs: UInt64, centerX: Double, centerY: Double, scale: Double, easeInMs: UInt64 = 300, easeOutMs: UInt64 = 400, easeEnabled: Bool = false, easingCurve: String = "easeInOut") {
        self.id = id
        self.timelineStartMs = timelineStartMs
        self.durationMs = durationMs
        self.centerX = centerX
        self.centerY = centerY
        self.scale = scale
        self.easeInMs = easeInMs
        self.easeOutMs = easeOutMs
        self.easeEnabled = easeEnabled
        self.easingCurve = easingCurve
    }

    /// Convert the string-based easing curve to the generated FFI enum.
    var easingCurveValue: EasingCurve {
        switch easingCurve {
        case "linear": return .linear
        case "easeIn": return .easeIn
        case "easeOut": return .easeOut
        case "easeInOut": return .easeInOut
        case "spring": return .spring
        default: return .easeInOut
        }
    }

    /// Backward-compatible decoding: defaults easingCurve to "easeInOut" if missing.
    enum CodingKeys: String, CodingKey {
        case id, timelineStartMs, durationMs, centerX, centerY, scale
        case easeInMs, easeOutMs, easeEnabled, easingCurve
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        timelineStartMs = try c.decode(UInt64.self, forKey: .timelineStartMs)
        durationMs = try c.decode(UInt64.self, forKey: .durationMs)
        centerX = try c.decode(Double.self, forKey: .centerX)
        centerY = try c.decode(Double.self, forKey: .centerY)
        scale = try c.decode(Double.self, forKey: .scale)
        easeInMs = try c.decode(UInt64.self, forKey: .easeInMs)
        easeOutMs = try c.decode(UInt64.self, forKey: .easeOutMs)
        easeEnabled = try c.decode(Bool.self, forKey: .easeEnabled)
        easingCurve = try c.decodeIfPresent(String.self, forKey: .easingCurve) ?? "easeInOut"
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
