import SwiftUI
import AVFoundation

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
    let videoWidth: Double
    let videoHeight: Double

    @State private var player: AVPlayer?
    @State private var timeObserver: Any?

    var body: some View { 
        GeometryReader { geo in
            ZStack {
                // Background — fills any area not covered by the video
                backgroundView

                if let player {
                    // Video and cursor in same coordinate space.
                    // Both are sized by the same GeometryReader and
                    // transformed by the same scaleEffect.
                    videoWithCursor(player: player, containerSize: geo.size)
                        .clipShape(RoundedRectangle(cornerRadius: styleConfig.cornerRadius))
                        .shadow(
                            color: .black.opacity(styleConfig.shadowEnabled ? styleConfig.shadowIntensity * 0.6 : 0),
                            radius: styleConfig.shadowEnabled ? 20 * styleConfig.shadowIntensity : 0,
                            y: styleConfig.shadowEnabled ? 10 * styleConfig.shadowIntensity : 0
                        )
                        .scaleEffect(currentScale, anchor: currentZoomAnchor)
                        .animation(.easeInOut(duration: 0.3), value: currentScale)
                        .animation(.easeInOut(duration: 0.3), value: currentZoomAnchor.x)
                        .animation(.easeInOut(duration: 0.3), value: currentZoomAnchor.y)
                        .padding(styleConfig.padding)
                        .zIndex(1)
                } else {
                    Text("No video loaded")
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
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

    /// Video and cursor composited together. The cursor is drawn as a Canvas
    /// that shares the exact same frame as the video, so they always move together.
    @ViewBuilder
    private func videoWithCursor(player: AVPlayer, containerSize: CGSize) -> some View {
        // Use the video's aspect ratio to determine the actual rendered size
        let padding = styleConfig.padding
        let availW = containerSize.width - padding * 2
        let availH = containerSize.height - padding * 2
        let videoAspect = videoWidth / max(videoHeight, 1)
        let viewAspect = availW / max(availH, 1)
        let renderW = videoAspect > viewAspect ? availW : availH * videoAspect
        let renderH = videoAspect > viewAspect ? availW / videoAspect : availH

        ZStack {
            VideoPlayerView(player: player)
            cursorCanvasView
        }
        .frame(width: renderW, height: renderH)
    }

    /// Canvas that draws the cursor at fractional position within its bounds.
    @ViewBuilder
    private var cursorCanvasView: some View {
        if cursorConfig.cursorStyle != "hidden", let point = currentCursorPoint {
            let fracX = point.x / max(videoWidth, 1)
            let fracY = point.y / max(videoHeight, 1)
            let baseSize = 12.0 * cursorConfig.sizeMultiplier

            Canvas { context, size in
                let x = fracX * size.width
                let y = fracY * size.height

                if cursorConfig.cursorStyle == "circle" {
                    if cursorConfig.clickHighlight {
                        let highlightSize = baseSize * 2.5
                        let highlightRect = CGRect(
                            x: x - highlightSize / 2, y: y - highlightSize / 2,
                            width: highlightSize, height: highlightSize
                        )
                        context.fill(
                            Path(ellipseIn: highlightRect),
                            with: .color(Color(hex: cursorConfig.highlightColorHex).opacity(0.25))
                        )
                    }
                    let dotRect = CGRect(
                        x: x - baseSize / 2, y: y - baseSize / 2,
                        width: baseSize, height: baseSize
                    )
                    context.fill(
                        Path(ellipseIn: dotRect),
                        with: .color(.white.opacity(0.9))
                    )
                } else if cursorConfig.cursorStyle == "system" {
                    // Draw system cursor image
                    let cursorImage = NSCursor.arrow.image
                    let cursorSize = CGSize(
                        width: cursorImage.size.width * cursorConfig.sizeMultiplier,
                        height: cursorImage.size.height * cursorConfig.sizeMultiplier
                    )
                    let hotSpot = NSCursor.arrow.hotSpot
                    let drawRect = CGRect(
                        x: x - hotSpot.x * cursorConfig.sizeMultiplier,
                        y: y - hotSpot.y * cursorConfig.sizeMultiplier,
                        width: cursorSize.width,
                        height: cursorSize.height
                    )
                    context.draw(
                        Image(nsImage: cursorImage),
                        in: drawRect
                    )
                }
            }
        }
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
            SystemCursorView(sizeMultiplier: cursorConfig.sizeMultiplier)
                .position(x: point.x, y: point.y)
        }
    }

    /// Compute the rect where the video renders within the given size (aspect-fit, centered).
    /// No padding — this is for the inner ZStack before padding is applied.
    private func videoDisplayRect(in size: CGSize) -> CGRect {
        guard videoWidth > 0, videoHeight > 0, size.width > 0, size.height > 0 else {
            return CGRect(origin: .zero, size: size)
        }

        let videoAspect = videoWidth / videoHeight
        let viewAspect = size.width / size.height

        let displayWidth: CGFloat
        let displayHeight: CGFloat

        if videoAspect > viewAspect {
            displayWidth = size.width
            displayHeight = size.width / videoAspect
        } else {
            displayHeight = size.height
            displayWidth = size.height * videoAspect
        }

        let x = (size.width - displayWidth) / 2
        let y = (size.height - displayHeight) / 2
        return CGRect(x: x, y: y, width: displayWidth, height: displayHeight)
    }

    private var currentScale: Double {
        let timestampMs = UInt64(currentTime * 1000)
        return zoomScaleAt(
            keyframes: keyframes,
            timestampMs: timestampMs,
            config: zoomConfig
        )
    }

    /// The anchor point for the zoom effect — zooms toward the click position.
    private var currentZoomAnchor: UnitPoint {
        let timestampMs = UInt64(currentTime * 1000)
        let center = zoomCenterAt(keyframes: keyframes, timestampMs: timestampMs)
        guard center.count == 2, videoWidth > 0, videoHeight > 0 else {
            return .center
        }
        // Normalize click position to 0..1 range within the video frame
        let anchorX = (center[0] / videoWidth).clamped(to: 0...1)
        let anchorY = (center[1] / videoHeight).clamped(to: 0...1)
        return UnitPoint(x: anchorX, y: anchorY)
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

/// Renders the macOS system arrow cursor as a SwiftUI view.
struct SystemCursorView: View {
    var sizeMultiplier: Double

    var body: some View {
        Image(nsImage: cursorImage)
            .resizable()
            .frame(width: cursorSize.width, height: cursorSize.height)
            .offset(x: cursorSize.width / 2 - hotSpot.x,
                    y: cursorSize.height / 2 - hotSpot.y)
            .shadow(color: .black.opacity(0.4), radius: 1, x: 0.5, y: 0.5)
    }

    private var cursorImage: NSImage {
        NSCursor.arrow.image
    }

    private var hotSpot: CGPoint {
        let hs = NSCursor.arrow.hotSpot
        return CGPoint(x: hs.x * sizeMultiplier, y: hs.y * sizeMultiplier)
    }

    private var cursorSize: CGSize {
        let img = NSCursor.arrow.image
        return CGSize(
            width: img.size.width * sizeMultiplier,
            height: img.size.height * sizeMultiplier
        )
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
        private let playerLayer = AVPlayerLayer()

        var player: AVPlayer? {
            didSet { playerLayer.player = player }
        }

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            playerLayer.videoGravity = .resizeAspect
            playerLayer.backgroundColor = CGColor.clear
            playerLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
            layer?.addSublayer(playerLayer)
            playerLayer.frame = bounds
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError()
        }
    }
}

private extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
