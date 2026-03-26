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
        .defaultSize(width: 960, height: 640)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Recording") {
                    appState.currentScreen = .recording
                }
                .keyboardShortcut("n")

                Divider()

                Button("Open Project...") {
                    openProject()
                }
                .keyboardShortcut("o")

                Button("Save Project") {
                    NotificationCenter.default.post(
                        name: .saveProject,
                        object: nil
                    )
                }
                .keyboardShortcut("s")
            }

            CommandGroup(after: .importExport) {
                Button("Export Video...") {
                    NotificationCenter.default.post(
                        name: .exportVideo,
                        object: nil
                    )
                }
                .keyboardShortcut("e")
            }
        }
    }

    private func openProject() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.init(filenameExtension: "demoreel")!]
        panel.allowsMultipleSelection = false

        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            let project = try loadProject(path: url.path)
            appState.videoPath = URL(fileURLWithPath: project.videoPath)
            appState.eventsPath = URL(fileURLWithPath: project.eventsPath)
            appState.projectPath = url
            appState.trimStartMs = project.trimStartMs
            appState.trimEndMs = project.trimEndMs
            appState.currentScreen = .editor
        } catch {
            let alert = NSAlert()
            alert.messageText = "Failed to open project"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }
}

extension Notification.Name {
    static let saveProject = Notification.Name("saveProject")
    static let exportVideo = Notification.Name("exportVideo")
}
