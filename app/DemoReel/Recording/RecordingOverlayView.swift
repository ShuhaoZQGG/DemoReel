import SwiftUI

/// Compact floating bar shown during recording: red dot, timer, stop/resume + finish buttons.
struct RecordingOverlayView: View {
    @Binding var elapsedSeconds: Int
    @Binding var isPaused: Bool
    var audioState: RecordingAudioState
    let onTogglePause: () -> Void
    let onFinish: () -> Void

    @State private var dotOpacity: Double = 1.0

    var body: some View {
        HStack(spacing: 12) {
            // Recording/paused indicator dot
            Circle()
                .fill(isPaused ? .orange : .red)
                .frame(width: 10, height: 10)
                .opacity(isPaused ? 1.0 : dotOpacity)
                .animation(
                    isPaused ? .default : .easeInOut(duration: 0.8).repeatForever(autoreverses: true),
                    value: dotOpacity
                )
                .onChange(of: isPaused) { _, paused in
                    dotOpacity = paused ? 1.0 : 0.3
                }
                .onAppear { dotOpacity = 0.3 }

            // Timer
            Text(formattedTime)
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(.white)

            Divider()
                .frame(height: 16)

            // System audio toggle
            Button(action: { audioState.systemAudioEnabled.toggle() }) {
                Image(systemName: audioState.systemAudioEnabled ? "speaker.wave.2.fill" : "speaker.slash.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(audioState.systemAudioEnabled ? .white : .white.opacity(0.5))
                    .frame(width: 32, height: 32)
                    .background(audioState.systemAudioEnabled ? Color.blue.opacity(0.4) : .white.opacity(0.1), in: Circle())
            }
            .buttonStyle(.plain)
            .help(audioState.systemAudioEnabled ? "System audio on" : "System audio off")

            // Microphone toggle
            Button(action: { audioState.micEnabled.toggle() }) {
                Image(systemName: audioState.micEnabled ? "mic.fill" : "mic.slash.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(audioState.micEnabled ? .white : .white.opacity(0.5))
                    .frame(width: 32, height: 32)
                    .background(audioState.micEnabled ? Color.green.opacity(0.4) : .white.opacity(0.1), in: Circle())
            }
            .buttonStyle(.plain)
            .help(audioState.micEnabled ? "Microphone on" : "Microphone off")

            // Pause / Resume button
            Button(action: onTogglePause) {
                Image(systemName: isPaused ? "play.fill" : "pause.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(.white.opacity(0.15), in: Circle())
            }
            .buttonStyle(.plain)

            // Finish button (stop square = end recording)
            Button(action: onFinish) {
                Image(systemName: "stop.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(.white.opacity(0.15), in: Circle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial.opacity(0.9))
        .background(Color.black.opacity(0.5))
        .clipShape(Capsule())
        .shadow(color: .black.opacity(0.3), radius: 8, y: 2)
    }

    private var formattedTime: String {
        let minutes = elapsedSeconds / 60
        let seconds = elapsedSeconds % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }
}
