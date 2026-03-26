import SwiftUI
import DemoReelCore

@main
struct DemoReelApp: App {
    @State private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            switch appState.currentScreen {
            case .recording:
                RecordingView(appState: appState)
            case .editor:
                EditorPlaceholderView(appState: appState)
            }
        }
        .defaultSize(width: 800, height: 600)
    }
}

/// Placeholder editor view until Milestone 2.
struct EditorPlaceholderView: View {
    @Bindable var appState: AppState

    var body: some View {
        VStack(spacing: 16) {
            Text("Recording Complete")
                .font(.title)

            if let videoPath = appState.videoPath {
                Text("Video: \(videoPath.lastPathComponent)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let eventsPath = appState.eventsPath {
                Text("Events: \(eventsPath.lastPathComponent)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text("Duration: \(Int(appState.recordingDuration))s")

            Button("New Recording") {
                appState.currentScreen = .recording
            }
        }
        .padding(40)
        .frame(minWidth: 500, minHeight: 350)
    }
}
