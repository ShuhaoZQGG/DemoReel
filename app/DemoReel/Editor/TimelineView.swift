import SwiftUI
import DemoReelCore

/// Horizontal scrollable timeline showing zoom keyframes and a playhead.
struct TimelineView: View {
    let keyframes: [ZoomKeyframe]
    let duration: TimeInterval
    @Binding var currentTime: Double
    @Binding var isPlaying: Bool

    @State private var pixelsPerSecond: Double = 100

    private var totalWidth: Double {
        max(duration * pixelsPerSecond, 1)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Transport controls
            HStack {
                Button(action: { isPlaying.toggle() }) {
                    Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.space, modifiers: [])

                Text(formattedTime(currentTime))
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.secondary)

                Text("/")
                    .foregroundStyle(.tertiary)

                Text(formattedTime(duration))
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.tertiary)

                Spacer()

                // Zoom level for timeline
                HStack(spacing: 4) {
                    Image(systemName: "minus.magnifyingglass")
                    Slider(value: $pixelsPerSecond, in: 30...300)
                        .frame(width: 100)
                    Image(systemName: "plus.magnifyingglass")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)

            Divider()

            // Timeline canvas
            ScrollView(.horizontal, showsIndicators: true) {
                ZStack(alignment: .topLeading) {
                    // Time ruler
                    TimeRuler(duration: duration, pixelsPerSecond: pixelsPerSecond)
                        .frame(height: 20)

                    // Keyframe track
                    ForEach(Array(keyframes.enumerated()), id: \.offset) { _, kf in
                        let x = Double(kf.startMs) / 1000.0 * pixelsPerSecond
                        let width = Double(kf.endMs - kf.startMs) / 1000.0 * pixelsPerSecond
                        RoundedRectangle(cornerRadius: 4)
                            .fill(.blue.opacity(0.3))
                            .overlay(
                                RoundedRectangle(cornerRadius: 4)
                                    .strokeBorder(.blue, lineWidth: 1)
                            )
                            .frame(width: max(width, 4), height: 32)
                            .offset(x: x, y: 24)
                    }

                    // Playhead
                    Rectangle()
                        .fill(.red)
                        .frame(width: 1.5)
                        .offset(x: currentTime * pixelsPerSecond)
                }
                .frame(width: totalWidth, height: 80)
                .contentShape(Rectangle())
                .onTapGesture { location in
                    let time = location.x / pixelsPerSecond
                    currentTime = max(0, min(time, duration))
                }
            }
        }
        .background(.background)
    }

    private func formattedTime(_ time: Double) -> String {
        let minutes = Int(time) / 60
        let seconds = Int(time) % 60
        let millis = Int((time.truncatingRemainder(dividingBy: 1)) * 10)
        return String(format: "%02d:%02d.%01d", minutes, seconds, millis)
    }
}

/// Draws time markers along the top of the timeline.
struct TimeRuler: View {
    let duration: TimeInterval
    let pixelsPerSecond: Double

    var body: some View {
        Canvas { context, size in
            let step = tickInterval()
            var t = 0.0
            while t <= duration {
                let x = t * pixelsPerSecond
                let isMajor = Int(t) % max(Int(step * 2), 1) == 0

                context.stroke(
                    Path { path in
                        path.move(to: CGPoint(x: x, y: isMajor ? 0 : 10))
                        path.addLine(to: CGPoint(x: x, y: 20))
                    },
                    with: .color(.secondary.opacity(0.5)),
                    lineWidth: isMajor ? 1 : 0.5
                )

                if isMajor {
                    let text = Text(String(format: "%.0fs", t))
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                    context.draw(
                        context.resolve(text),
                        at: CGPoint(x: x + 2, y: 4),
                        anchor: .topLeading
                    )
                }

                t += step
            }
        }
    }

    private func tickInterval() -> Double {
        if pixelsPerSecond > 150 { return 0.5 }
        if pixelsPerSecond > 60 { return 1.0 }
        return 2.0
    }
}
