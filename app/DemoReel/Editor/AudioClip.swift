import Foundation

/// A time range where an audio source was enabled during recording.
struct AudioSegment {
    let startMs: UInt64
    let endMs: UInt64
}

/// An editable audio clip on the timeline, independent of video clips.
struct AudioClip: Identifiable, Codable, Equatable {
    let id: UUID
    var sourceStartMs: UInt64
    var sourceEndMs: UInt64
    var timelineStartMs: UInt64
    var mediaItemId: UUID?
    var trackIndex: Int             // 0 = system audio, 1 = mic
    var volume: Double
    var isMuted: Bool

    init(
        id: UUID = UUID(),
        sourceStartMs: UInt64,
        sourceEndMs: UInt64,
        timelineStartMs: UInt64 = 0,
        mediaItemId: UUID? = nil,
        trackIndex: Int = 0,
        volume: Double = 1.0,
        isMuted: Bool = false
    ) {
        self.id = id
        self.sourceStartMs = sourceStartMs
        self.sourceEndMs = sourceEndMs
        self.timelineStartMs = timelineStartMs
        self.mediaItemId = mediaItemId
        self.trackIndex = trackIndex
        self.volume = volume
        self.isMuted = isMuted
    }

    var sourceDurationMs: UInt64 {
        sourceEndMs - sourceStartMs
    }

    var sourceDuration: Double {
        Double(sourceDurationMs) / 1000.0
    }

    var timelineEndMs: UInt64 {
        timelineStartMs + sourceDurationMs
    }

    /// Backward-compatible decoding: defaults volume/isMuted if missing.
    enum CodingKeys: String, CodingKey {
        case id, sourceStartMs, sourceEndMs, timelineStartMs, mediaItemId
        case trackIndex, volume, isMuted
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        sourceStartMs = try c.decode(UInt64.self, forKey: .sourceStartMs)
        sourceEndMs = try c.decode(UInt64.self, forKey: .sourceEndMs)
        timelineStartMs = try c.decode(UInt64.self, forKey: .timelineStartMs)
        mediaItemId = try c.decodeIfPresent(UUID.self, forKey: .mediaItemId)
        trackIndex = try c.decodeIfPresent(Int.self, forKey: .trackIndex) ?? 0
        volume = try c.decodeIfPresent(Double.self, forKey: .volume) ?? 1.0
        isMuted = try c.decodeIfPresent(Bool.self, forKey: .isMuted) ?? false
    }
}
