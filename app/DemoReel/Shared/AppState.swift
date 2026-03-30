import SwiftUI
import Combine

/// Observable app state shared across views.
@Observable
final class AppState {
    enum Screen {
        case recording
        case editor
    }

    var currentScreen: Screen = .recording

    // Recording state
    var isRecording = false
    var recordingDuration: TimeInterval = 0
    var selectedWindowTitle: String?

    // Paths from the last completed recording
    var videoPath: URL?
    var eventsPath: URL?

    // Project state
    var projectPath: URL?

    // Trim state (milliseconds)
    var trimStartMs: UInt64 = 0
    var trimEndMs: UInt64 = 0

    // Audio segments from recording (enabled time ranges per source)
    var systemAudioSegments: [AudioSegment] = []
    var micAudioSegments: [AudioSegment] = []

    /// Directory where recordings are saved.
    static var recordingsDirectory: URL {
        let movies = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first!
        return movies.appendingPathComponent("DemoReel", isDirectory: true)
    }

    /// Ensure the recordings directory exists.
    static func ensureRecordingsDirectory() throws {
        try FileManager.default.createDirectory(
            at: recordingsDirectory,
            withIntermediateDirectories: true
        )
    }
}
