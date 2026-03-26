import SwiftUI
import AVFoundation
import DemoReelCore

/// Video preview with zoom, style, and cursor rendering applied in real-time.
struct PreviewView: View {
    let videoURL: URL?
    let keyframes: [ZoomKeyframe]
    let smoothedPoints: [SmoothedPoint]
    @Binding var currentTime: Double
    @Binding var isPlaying: Bool
    let zoomConfig: ZoomConfig
    let styleConfig: StyleConfig
    let cursorConfig: CursorConfig

    @State private var player: AVPlayer?
    @State private var timeObserver: Any?

    var body: some View {
        GeometryReader { geo in
            ZStack {
                // Background
                backgroundView
                    .frame(width: geo.size.width, height: geo.size.height)

                if let player {
                    // Video frame with styling
                    VideoPlayerView(player: player)
                        .clipShape(RoundedRectangle(cornerRadius: styleConfig.cornerRadius))
                        .shadow(
                            color: .black.opacity(styleConfig.shadowEnabled ? styleConfig.shadowIntensity * 0.6 : 0),
                            radius: styleConfig.shadowEnabled ? 20 * styleConfig.shadowIntensity : 0,
                            y: styleConfig.shadowEnabled ? 10 * styleConfig.shadowIntensity : 0
                        )
                        .scaleEffect(currentScale)
                        .animation(.easeInOut(duration: 0.05), value: currentScale)
                        .padding(styleConfig.padding)

                    // Cursor overlay
                    if cursorConfig.cursorStyle != "hidden", let point = currentCursorPoint {
                        cursorOverlay(at: point, in: geo.size)
                    }
                } else {
                    Text("No video loaded")
                        .foregroundStyle(.secondary)
                }
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

    @ViewBuilder
    private var backgroundView: some View {
        switch styleConfig.background.bgType {
        case "gradient":
            LinearGradient(
                colors: [
                    Color(hex: styleConfig.background.gradientFromHex),
                    Color(hex: styleConfig.background.gradientToHex),
                ],
                startPoint: gradientStart,
                endPoint: gradientEnd
            )
        case "transparent":
            // Checkerboard pattern to indicate transparency
            Canvas { context, size in
                let cellSize: CGFloat = 10
                for row in 0..<Int(size.height / cellSize) + 1 {
                    for col in 0..<Int(size.width / cellSize) + 1 {
                        let isLight = (row + col) % 2 == 0
                        context.fill(
                            Path(CGRect(
                                x: CGFloat(col) * cellSize,
                                y: CGFloat(row) * cellSize,
                                width: cellSize,
                                height: cellSize
                            )),
                            with: .color(isLight ? .white.opacity(0.3) : .gray.opacity(0.3))
                        )
                    }
                }
            }
        default: // "solid"
            Color(hex: styleConfig.background.hex)
        }
    }

    private var gradientStart: UnitPoint {
        let angle = styleConfig.background.gradientAngleDegrees
        let rad = angle * .pi / 180.0
        return UnitPoint(x: 0.5 - cos(rad) * 0.5, y: 0.5 - sin(rad) * 0.5)
    }

    private var gradientEnd: UnitPoint {
        let angle = styleConfig.background.gradientAngleDegrees
        let rad = angle * .pi / 180.0
        return UnitPoint(x: 0.5 + cos(rad) * 0.5, y: 0.5 + sin(rad) * 0.5)
    }

    @ViewBuilder
    private func cursorOverlay(at point: SmoothedPoint, in size: CGSize) -> some View {
        let baseSize = 12.0 * cursorConfig.sizeMultiplier

        if cursorConfig.cursorStyle == "circle" {
            ZStack {
                if cursorConfig.clickHighlight {
                    Circle()
                        .fill(Color(hex: cursorConfig.highlightColorHex).opacity(0.25))
                        .frame(width: baseSize * 2.5, height: baseSize * 2.5)
                }
                Circle()
                    .fill(.white.opacity(0.9))
                    .frame(width: baseSize, height: baseSize)
                    .shadow(color: .black.opacity(0.3), radius: 2)
            }
            .position(x: point.x, y: point.y)
        } else if cursorConfig.cursorStyle == "system" {
            Image(systemName: "cursorarrow")
                .font(.system(size: 16 * cursorConfig.sizeMultiplier))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.5), radius: 1)
                .position(x: point.x, y: point.y)
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
