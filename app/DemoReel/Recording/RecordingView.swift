import SwiftUI
import ScreenCaptureKit

/// Main recording UI: source picker buttons, and a compact recording indicator.
struct RecordingView: View {
    @Bindable var appState: AppState
    @State private var recorder = ScreenRecorder()
    @State private var eventLogger = EventLogger()
    @State private var audioCapture = AudioCapture()
    @State private var pickerCoordinator = SourcePickerCoordinator()
    @State private var timer: Timer?
    @State private var elapsedSeconds: Int = 0
    @State private var errorMessage: String?
    @State private var hasAccessibilityPermission = false
    @State private var overlayPanel: RecordingOverlayPanel?

    var body: some View {
        VStack(spacing: 24) {
            if recorder.isRecording {
                recordingActiveView
            } else {
                sourceSelectionView
            }
        }
        .padding(40)
        .frame(minWidth: 500, minHeight: 350)
        .onAppear {
            checkAccessibilityPermission()
        }
        .onChange(of: pickerCoordinator.selectedFilter) { _, filter in
            guard let filter else { return }
            Task { await startRecording(filter: filter) }
        }
    }

    // MARK: - Source selection (before recording)

    private var sourceSelectionView: some View {
        VStack(spacing: 32) {
            Text("DemoReel")
                .font(.largeTitle)
                .fontWeight(.bold)

            if !hasAccessibilityPermission {
                accessibilityBanner
            }

            Text("Choose what to record")
                .foregroundStyle(.secondary)

            HStack(spacing: 20) {
                CaptureOptionButton(
                    title: "Window",
                    systemImage: "macwindow",
                    description: "Click a window"
                ) {
                    presentPicker()
                }

                CaptureOptionButton(
                    title: "Screen",
                    systemImage: "display",
                    description: "Full display"
                ) {
                    presentPicker()
                }
            }

            if let error = errorMessage {
                Text(error)
                    .foregroundStyle(.red)
                    .font(.caption)
            }
        }
    }

    private var accessibilityBanner: some View {
        VStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text("Accessibility permission required")
                    .font(.headline)
            }

            Text("DemoReel needs Accessibility access to track cursor activity in other apps.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Button("Open System Settings") {
                openAccessibilitySettings()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
        .padding(16)
        .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(.orange.opacity(0.3)))
    }

    // MARK: - Recording active view

    private var recordingActiveView: some View {
        VStack(spacing: 16) {
            HStack(spacing: 8) {
                Circle()
                    .fill(.red)
                    .frame(width: 12, height: 12)

                Text("Recording")
                    .font(.headline)
                    .foregroundStyle(.red)
            }

            Text(formattedTime)
                .font(.system(.largeTitle, design: .monospaced))
                .foregroundStyle(.primary)

            Button("Stop Recording") {
                Task { await stopRecording() }
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .controlSize(.large)
            .keyboardShortcut(.escape, modifiers: [])
        }
    }

    // MARK: - Actions

    private func presentPicker() {
        errorMessage = nil
        // Hide the main window so user can see/click other windows
        NSApplication.shared.mainWindow?.miniaturize(nil)

        // Small delay to let the window minimize before showing picker
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            pickerCoordinator.present()
        }
    }

    private func startRecording(filter: SCContentFilter) async {
        errorMessage = nil

        do {
            try AppState.ensureRecordingsDirectory()
            let recordingId = UUID().uuidString
            let videoURL = AppState.recordingsDirectory
                .appendingPathComponent("\(recordingId).mov")

            try await recorder.startRecording(filter: filter, outputURL: videoURL)

            // captureRect.origin is already in Quartz screen coords (top-left origin),
            // confirmed by matching CGWindowList kCGWindowBounds values.
            // Use it directly — no coordinate conversion needed.
            let mainScreenHeight = NSScreen.main?.frame.height ?? 0
            eventLogger.startLogging(
                windowQuartzOrigin: recorder.captureRect.origin,
                screenHeight: mainScreenHeight
            )
            audioCapture.start()

            elapsedSeconds = 0
            timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
                elapsedSeconds += 1
            }

            appState.isRecording = true

            // Hide main window, show floating overlay instead
            NSApplication.shared.mainWindow?.orderOut(nil)
            showOverlay()
        } catch {
            errorMessage = error.localizedDescription
            NSApplication.shared.activate(ignoringOtherApps: true)
        }
    }

    private func stopRecording() async {
        timer?.invalidate()
        timer = nil
        dismissOverlay()

        eventLogger.stopLogging()
        audioCapture.stop()

        do {
            guard let videoURL = try await recorder.stopRecording() else { return }

            let recordingId = videoURL.deletingPathExtension().lastPathComponent
            let eventsURL = videoURL.deletingPathExtension()
                .appendingPathExtension("events.json")

            let durationMs = UInt64(elapsedSeconds) * 1000
            let captureRect = recorder.captureRect

            try eventLogger.save(
                to: eventsURL,
                recordingId: recordingId,
                durationMs: durationMs,
                screenWidth: UInt32(captureRect.width),
                screenHeight: UInt32(captureRect.height)
            )

            appState.videoPath = videoURL
            appState.eventsPath = eventsURL
            appState.isRecording = false
            appState.recordingDuration = TimeInterval(elapsedSeconds)

            // Show main window and switch to editor
            NSApplication.shared.activate(ignoringOtherApps: true)
            for window in NSApplication.shared.windows where window !== overlayPanel {
                window.makeKeyAndOrderFront(nil)
            }
            appState.currentScreen = .editor
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private var formattedTime: String {
        let minutes = elapsedSeconds / 60
        let seconds = elapsedSeconds % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }

    // MARK: - Floating overlay

    private func showOverlay() {
        let overlayView = RecordingOverlayView(
            elapsedSeconds: $elapsedSeconds,
            onStop: { Task { await stopRecording() } }
        )
        let hostingView = NSHostingView(rootView: overlayView)
        hostingView.frame = NSRect(x: 0, y: 0, width: 220, height: 44)

        let panel = RecordingOverlayPanel(contentView: hostingView)
        panel.orderFront(nil)
        overlayPanel = panel
    }

    private func dismissOverlay() {
        overlayPanel?.orderOut(nil)
        overlayPanel = nil
    }

    // MARK: - Accessibility permission

    private func checkAccessibilityPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        hasAccessibilityPermission = AXIsProcessTrustedWithOptions(options)
    }

    private func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
        // Poll for permission change after user grants it in Settings
        pollForAccessibilityPermission()
    }

    private func pollForAccessibilityPermission() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            if AXIsProcessTrusted() {
                hasAccessibilityPermission = true
            } else {
                pollForAccessibilityPermission()
            }
        }
    }
}

/// A styled button for choosing a capture source type.
private struct CaptureOptionButton: View {
    let title: String
    let systemImage: String
    let description: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 12) {
                Image(systemName: systemImage)
                    .font(.system(size: 32))
                    .frame(height: 40)

                Text(title)
                    .font(.headline)

                Text(description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(width: 140, height: 120)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
    }
}
