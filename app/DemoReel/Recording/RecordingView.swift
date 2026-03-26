import SwiftUI
import ScreenCaptureKit

/// Main recording UI: source picker, record/stop button, timer.
struct RecordingView: View {
    @Bindable var appState: AppState
    @State private var recorder = ScreenRecorder()
    @State private var eventLogger = EventLogger()
    @State private var audioCapture = AudioCapture()
    @State private var timer: Timer?
    @State private var elapsedSeconds: Int = 0
    @State private var selectedWindow: SCWindow?
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 24) {
            Text("DemoReel")
                .font(.largeTitle)
                .fontWeight(.bold)

            if recorder.availableWindows.isEmpty {
                Button("Refresh Windows") {
                    Task { try? await recorder.refreshAvailableSources() }
                }
            } else {
                Picker("Window", selection: $selectedWindow) {
                    Text("Select a window...").tag(nil as SCWindow?)
                    ForEach(recorder.availableWindows, id: \.windowID) { window in
                        Text(windowLabel(window)).tag(window as SCWindow?)
                    }
                }
                .frame(maxWidth: 400)
            }

            if recorder.isRecording {
                Text(formattedTime)
                    .font(.system(.title, design: .monospaced))
                    .foregroundStyle(.red)

                Button("Stop Recording") {
                    Task { await stopRecording() }
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .controlSize(.large)
            } else {
                Button("Record") {
                    Task { await startRecording() }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(selectedWindow == nil)
            }

            if let error = errorMessage {
                Text(error)
                    .foregroundStyle(.red)
                    .font(.caption)
            }
        }
        .padding(40)
        .frame(minWidth: 500, minHeight: 350)
        .task {
            try? await recorder.refreshAvailableSources()
        }
    }

    private var formattedTime: String {
        let minutes = elapsedSeconds / 60
        let seconds = elapsedSeconds % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }

    private func windowLabel(_ window: SCWindow) -> String {
        let app = window.owningApplication?.applicationName ?? "Unknown"
        let title = window.title ?? ""
        if title.isEmpty {
            return app
        }
        return "\(app) — \(title)"
    }

    private func startRecording() async {
        guard let window = selectedWindow else { return }
        errorMessage = nil

        do {
            try AppState.ensureRecordingsDirectory()
            let recordingId = UUID().uuidString
            let videoURL = AppState.recordingsDirectory
                .appendingPathComponent("\(recordingId).mov")

            try await recorder.startRecording(window: window, outputURL: videoURL)
            eventLogger.startLogging()
            audioCapture.start()

            elapsedSeconds = 0
            timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
                elapsedSeconds += 1
            }

            appState.isRecording = true
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func stopRecording() async {
        timer?.invalidate()
        timer = nil

        eventLogger.stopLogging()
        audioCapture.stop()

        do {
            guard let videoURL = try await recorder.stopRecording() else { return }

            let recordingId = videoURL.deletingPathExtension().lastPathComponent
            let eventsURL = videoURL.deletingPathExtension()
                .appendingPathExtension("events.json")

            let durationMs = UInt64(elapsedSeconds) * 1000
            try eventLogger.save(
                to: eventsURL,
                recordingId: recordingId,
                durationMs: durationMs,
                screenWidth: 1920,
                screenHeight: 1080
            )

            appState.videoPath = videoURL
            appState.eventsPath = eventsURL
            appState.isRecording = false
            appState.recordingDuration = TimeInterval(elapsedSeconds)
            appState.currentScreen = .editor
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
