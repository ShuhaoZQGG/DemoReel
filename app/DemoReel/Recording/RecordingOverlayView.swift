import SwiftUI

/// Compact floating bar shown during recording: red dot, timer, stop button.
struct RecordingOverlayView: View {
    @Binding var elapsedSeconds: Int
    let onStop: () -> Void

    @State private var dotOpacity: Double = 1.0

    var body: some View {
        HStack(spacing: 12) {
            // Pulsing red recording dot
            Circle()
                .fill(.red)
                .frame(width: 10, height: 10)
                .opacity(dotOpacity)
                .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: dotOpacity)
                .onAppear { dotOpacity = 0.3 }

            // Timer
            Text(formattedTime)
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(.white)

            Divider()
                .frame(height: 16)

            // Stop button
            Button(action: onStop) {
                HStack(spacing: 4) {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 10))
                    Text("Stop")
                        .font(.system(.callout, weight: .medium))
                }
                .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
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
