import Foundation

/// A segment of the source video with independent speed.
struct Clip: Identifiable, Codable {
    let id: UUID
    var sourceStartMs: UInt64
    var sourceEndMs: UInt64
    var speed: Double
    /// Position on the visual/output timeline (ms). Determines where the clip appears.
    var timelineStartMs: UInt64

    init(id: UUID = UUID(), sourceStartMs: UInt64, sourceEndMs: UInt64, speed: Double = 1.0, timelineStartMs: UInt64 = 0) {
        self.id = id
        self.sourceStartMs = sourceStartMs
        self.sourceEndMs = sourceEndMs
        self.speed = speed
        self.timelineStartMs = timelineStartMs
    }

    /// Duration in the source video (seconds).
    var sourceDuration: Double {
        Double(sourceEndMs - sourceStartMs) / 1000.0
    }

    /// End position on the visual/output timeline (ms).
    var timelineEndMs: UInt64 {
        timelineStartMs + UInt64(sourceDuration * 1000)
    }

    /// Duration as it appears on the playback timeline (seconds), accounting for speed.
    var playbackDuration: Double {
        sourceDuration / speed
    }
}
