import Foundation

/// A video file in the media pool, available for placement on the timeline.
struct MediaItem: Identifiable, Codable, Equatable {
    let id: UUID
    var filePath: String
    var durationMs: UInt64
    var width: Double
    var height: Double
    var name: String

    init(id: UUID = UUID(), filePath: String, durationMs: UInt64, width: Double, height: Double, name: String) {
        self.id = id
        self.filePath = filePath
        self.durationMs = durationMs
        self.width = width
        self.height = height
        self.name = name
    }

    var fileURL: URL {
        URL(fileURLWithPath: filePath)
    }
}
