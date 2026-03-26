import SwiftUI
import AVFoundation
import DemoReelCore

/// Video preview with zoom transform applied based on current keyframes.
struct PreviewView: View {
    let videoURL: URL?
    let keyframes: [ZoomKeyframe]
    let smoothedPoints: [SmoothedPoint]
    @Binding var currentTime: Double
    @Binding var isPlaying: Bool
    let zoomConfig: ZoomConfig

    @State private var player: AVPlayer?
    @State private var timeObserver: Any?

    var body: some View {
        ZStack {
            Color.black

            if let player {
                VideoPlayerView(player: player)
                    .scaleEffect(currentScale)
                    .animation(.easeInOut(duration: 0.05), value: currentScale)

                // Cursor overlay
                if let point = currentCursorPoint {
                    Circle()
                        .fill(.white.opacity(0.8))
                        .frame(width: 12, height: 12)
                        .shadow(color: .black.opacity(0.3), radius: 2)
                        .position(
                            x: point.x,
                            y: point.y
                        )
                }
            } else {
                Text("No video loaded")
                    .foregroundStyle(.secondary)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .padding(8)
        .onChange(of: videoURL) { _, newURL in
            setupPlayer(url: newURL)
        }
        .onChange(of: isPlaying) { _, playing in
            if playing {
                player?.play()
            } else {
                player?.pause()
            }
        }
        .onChange(of: currentTime) { _, newTime in
            if !isPlaying {
                let cmTime = CMTime(seconds: newTime, preferredTimescale: 600)
                player?.seek(to: cmTime, toleranceBefore: .zero, toleranceAfter: .zero)
            }
        }
        .onAppear {
            setupPlayer(url: videoURL)
        }
        .onDisappear {
            removeTimeObserver()
        }
    }

    private var currentScale: Double {
        let timestampMs = UInt64(currentTime * 1000)
        return zoomScaleAt(
            keyframes: keyframes,
            timestampMs: timestampMs,
            config: zoomConfig
        )
    }

    private var currentCursorPoint: SmoothedPoint? {
        let timestampMs = UInt64(currentTime * 1000)
        return smoothedPoints.last(where: { $0.timestampMs <= timestampMs })
    }

    private func setupPlayer(url: URL?) {
        removeTimeObserver()
        guard let url else {
            player = nil
            return
        }

        let newPlayer = AVPlayer(url: url)
        player = newPlayer

        let interval = CMTime(value: 1, timescale: 30)
        timeObserver = newPlayer.addPeriodicTimeObserver(
            forInterval: interval,
            queue: .main
        ) { time in
            if isPlaying {
                currentTime = time.seconds
            }
        }
    }

    private func removeTimeObserver() {
        if let observer = timeObserver {
            player?.removeTimeObserver(observer)
            timeObserver = nil
        }
    }
}

/// NSViewRepresentable wrapper for AVPlayerLayer.
struct VideoPlayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> NSView {
        let view = PlayerNSView()
        view.player = player
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? PlayerNSView)?.player = player
    }

    class PlayerNSView: NSView {
        var player: AVPlayer? {
            didSet {
                (layer as? AVPlayerLayer)?.player = player
            }
        }

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            layer = AVPlayerLayer()
            (layer as? AVPlayerLayer)?.videoGravity = .resizeAspect
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError()
        }
    }
}
