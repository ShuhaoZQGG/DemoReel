import Foundation

/// A segment of a source video with independent speed.
struct Clip: Identifiable, Codable, Equatable {
    let id: UUID
    var sourceStartMs: UInt64
    var sourceEndMs: UInt64
    var speed: Double
    /// Position on the visual/output timeline (ms). Determines where the clip appears.
    var timelineStartMs: UInt64
    /// Which media pool item this clip references. Nil for legacy single-source projects.
    var mediaItemId: UUID?

    init(id: UUID = UUID(), sourceStartMs: UInt64, sourceEndMs: UInt64, speed: Double = 1.0, timelineStartMs: UInt64 = 0, mediaItemId: UUID? = nil) {
        self.id = id
        self.sourceStartMs = sourceStartMs
        self.sourceEndMs = sourceEndMs
        self.speed = speed
        self.timelineStartMs = timelineStartMs
        self.mediaItemId = mediaItemId
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
