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
                EditorView(appState: appState)
            }
        }
        .defaultSize(width: 800, height: 600)
    }
}

