import SwiftUI
import AVFoundation

/// Video preview with zoom, style, and cursor rendering applied in real-time.
struct PreviewView: View {
    let videoURL: URL?
    let keyframes: [ZoomKeyframe]
    let zoomClips: [ZoomClip]
    let smoothedPoints: [SmoothedPoint]
    @Binding var currentTime: Double
    let timelinePosition: Double
    @Binding var isPlaying: Bool
    let zoomConfig: ZoomConfig
    let styleConfig: StyleConfig
    let cursorConfig: CursorConfig
    let videoWidth: Double
    let videoHeight: Double
    var selection: TrackSelection = .none
    var systemAudioClips: [AudioClip] = []
    var micAudioClips: [AudioClip] = []
    var onFocusPointDragged: ((UUID, Double, Double) -> Void)?
    var onDragBegan: (() -> Void)?

    @State private var player: AVPlayer?
    /// Cache of AVPlayers keyed by URL path, to avoid re-creating players when switching between sources.
    @State private var playerCache: [String: AVPlayer] = [:]
    /// Tracks whether undo state has been saved for the current drag gesture.
    @State private var dragUndoSaved = false

    var body: some View { 
        GeometryReader { geo in
            ZStack {
                // Background — fills any area not covered by the video
                backgroundView

                if currentTime < 0 {
                    // Gap — show black (standard NLE behavior)
                    Color.black
                        .zIndex(1)
                } else if let player {
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

                    // Draggable focus point overlay — outside scaleEffect
                    focusPointOverlay(containerSize: geo.size)
                        .zIndex(2)
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
        .onChange(of: currentTime) { _, newTime in
            guard newTime >= 0 else { return }
            if isPlaying {
                // During playback, let AVPlayer play for audio output.
                // Only seek when the player drifts too far from the expected position.
                if player?.rate == 0 {
                    let cmTime = CMTime(seconds: newTime, preferredTimescale: 600)
                    player?.seek(to: cmTime, toleranceBefore: .zero, toleranceAfter: .zero)
                    player?.play()
                } else if let currentPlayerTime = player?.currentTime().seconds {
                    let drift = abs(currentPlayerTime - newTime)
                    if drift > 0.15 {
                        let cmTime = CMTime(seconds: newTime, preferredTimescale: 600)
                        player?.seek(to: cmTime, toleranceBefore: .zero, toleranceAfter: .zero)
                    }
                }
            } else {
                // When not playing (scrubbing), seek frame-by-frame.
                player?.pause()
                let cmTime = CMTime(seconds: newTime, preferredTimescale: 600)
                player?.seek(to: cmTime, toleranceBefore: .zero, toleranceAfter: .zero)
            }
        }
        .onChange(of: isPlaying) { _, playing in
            if !playing {
                player?.pause()
            }
        }
        .onChange(of: timelinePosition) { _, _ in
            updatePlayerAudioState()
        }
        .onChange(of: systemAudioClips) { _, _ in
            updatePlayerAudioState()
        }
        .onChange(of: micAudioClips) { _, _ in
            updatePlayerAudioState()
        }
        .onAppear {
            setupPlayer(url: videoURL)
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
        case "image":
            if let nsImage = NSImage(named: styleConfig.background.imageName) {
                Image(nsImage: nsImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
            } else {
                Color(hex: "#1a1a2e")
            }
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

    /// Compute the video render size and origin within the container, accounting for padding.
    private func videoRenderRect(in containerSize: CGSize) -> (origin: CGPoint, size: CGSize) {
        let padding = styleConfig.padding
        let availW = containerSize.width - padding * 2
        let availH = containerSize.height - padding * 2
        let videoAspect = videoWidth / max(videoHeight, 1)
        let viewAspect = availW / max(availH, 1)
        let renderW = videoAspect > viewAspect ? availW : availH * videoAspect
        let renderH = videoAspect > viewAspect ? availW / videoAspect : availH
        let originX = (containerSize.width - renderW) / 2
        let originY = (containerSize.height - renderH) / 2
        return (CGPoint(x: originX, y: originY), CGSize(width: renderW, height: renderH))
    }

    /// Video and cursor composited together. The cursor is drawn as a Canvas
    /// that shares the exact same frame as the video, so they always move together.
    @ViewBuilder
    private func videoWithCursor(player: AVPlayer, containerSize: CGSize) -> some View {
        let rect = videoRenderRect(in: containerSize)

        ZStack {
            VideoPlayerView(player: player)
            cursorCanvasView
        }
        .frame(width: rect.size.width, height: rect.size.height)
    }

    /// Cursor overlay using standard SwiftUI views (not Canvas) so both
    /// preview and export share the same rendering path.
    @ViewBuilder
    private var cursorCanvasView: some View {
        if cursorConfig.cursorStyle != "hidden", let point = currentCursorPoint {
            let fracX = point.x / max(videoWidth, 1)
            let fracY = point.y / max(videoHeight, 1)
            let baseSize = 12.0 * cursorConfig.sizeMultiplier

            GeometryReader { geo in
                let x = fracX * geo.size.width
                let y = fracY * geo.size.height

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
                    .position(x: x, y: y)
                } else if cursorConfig.cursorStyle == "system" {
                    SystemCursorView(sizeMultiplier: cursorConfig.sizeMultiplier)
                        .position(x: x, y: y)
                }
            }
        }
    }

    /// The zoom clip that is both the sole selection and contains the current playhead.
    /// Returns nil when follow-cursor mode is active (center is dynamically tracked).
    private var activeOverlayClip: ZoomClip? {
        guard !zoomConfig.followCursor else { return nil }
        guard case .zoomClips(let ids) = selection, ids.count == 1,
              let id = ids.first else { return nil }
        let timestampMs = UInt64(max(0, timelinePosition) * 1000)
        return zoomClips.first { $0.id == id && timestampMs >= $0.timelineStartMs && timestampMs <= $0.timelineEndMs }
    }

    /// Draggable crosshair overlay for repositioning the zoom focus point.
    @ViewBuilder
    private func focusPointOverlay(containerSize: CGSize) -> some View {
        if let clip = activeOverlayClip, videoWidth > 0, videoHeight > 0 {
            let rect = videoRenderRect(in: containerSize)
            let fracX = clip.centerX / videoWidth
            let fracY = clip.centerY / videoHeight
            let displayX = rect.origin.x + fracX * rect.size.width
            let displayY = rect.origin.y + fracY * rect.size.height

            ZStack {
                // Crosshair lines
                Rectangle()
                    .fill(.white.opacity(0.6))
                    .frame(width: 1, height: 24)
                Rectangle()
                    .fill(.white.opacity(0.6))
                    .frame(width: 24, height: 1)
                // Center circle
                Circle()
                    .stroke(.white, lineWidth: 1.5)
                    .frame(width: 16, height: 16)
                Circle()
                    .fill(.white.opacity(0.2))
                    .frame(width: 16, height: 16)
            }
            .shadow(color: .black.opacity(0.5), radius: 2)
            .position(x: displayX, y: displayY)
            .contentShape(Rectangle().size(width: 32, height: 32).offset(x: -16, y: -16))
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        if !dragUndoSaved {
                            dragUndoSaved = true
                            onDragBegan?()
                        }
                        let newCenterX = ((value.location.x - rect.origin.x) / rect.size.width * videoWidth)
                            .clamped(to: 0...videoWidth)
                        let newCenterY = ((value.location.y - rect.origin.y) / rect.size.height * videoHeight)
                            .clamped(to: 0...videoHeight)
                        onFocusPointDragged?(clip.id, newCenterX, newCenterY)
                    }
                    .onEnded { _ in
                        dragUndoSaved = false
                    }
            )
        }
    }

    private var currentScale: Double {
        // Use timeline position (zoom clips are in timeline coordinates)
        let timestampMs = UInt64(max(0, timelinePosition) * 1000)
        return ClipManager.zoomScaleWithPerClipEase(
            zoomClips: zoomClips,
            timestampMs: timestampMs,
            globalConfig: zoomConfig
        )
    }

    /// The anchor point for the zoom effect — zooms toward the cursor position.
    private var currentZoomAnchor: UnitPoint {
        let timestampMs = UInt64(max(0, timelinePosition) * 1000)

        guard videoWidth > 0, videoHeight > 0 else { return .center }

        // Find the active zoom clip to get per-clip ease config
        guard let clip = zoomClips.first(where: {
            timestampMs >= $0.timelineStartMs && timestampMs <= $0.timelineEndMs
        }) else {
            return .center
        }

        // Always derive hold from clip duration — global holdMs is only for auto-generation
        let easeIn = clip.easeEnabled ? clip.easeInMs : zoomConfig.easeInMs
        let easeOut = clip.easeEnabled ? clip.easeOutMs : zoomConfig.easeOutMs
        let holdMs = clip.durationMs > (easeIn + easeOut)
            ? clip.durationMs - easeIn - easeOut
            : 0
        let effectiveConfig = zoomConfig.with(
            easeInMs: easeIn,
            holdMs: holdMs,
            easeOutMs: easeOut
        )

        // Try dynamic cursor-following center
        if effectiveConfig.followCursor {
            // Build a keyframe matching this clip's timeline span
            let kf = [ZoomKeyframe(
                startMs: clip.timelineStartMs, endMs: clip.timelineEndMs,
                centerX: clip.centerX, centerY: clip.centerY, scale: clip.scale
            )]
            let centerVec = zoomCenterAtFollowing(
                keyframes: kf,
                smoothedPath: smoothedPoints,
                timestampMs: timestampMs,
                config: effectiveConfig
            )
            if centerVec.count == 2 {
                let anchorX = (centerVec[0] / videoWidth).clamped(to: 0...1)
                let anchorY = (centerVec[1] / videoHeight).clamped(to: 0...1)
                return UnitPoint(x: anchorX, y: anchorY)
            }
        }

        // Fall back to static center
        let anchorX = (clip.centerX / videoWidth).clamped(to: 0...1)
        let anchorY = (clip.centerY / videoHeight).clamped(to: 0...1)
        return UnitPoint(x: anchorX, y: anchorY)
    }

    private var currentCursorPoint: SmoothedPoint? {
        let timestampMs = UInt64(currentTime * 1000)
        return smoothedPoints.last(where: { $0.timestampMs <= timestampMs })
    }

    /// Update AVPlayer per-track volume via AVAudioMix based on audio clip state.
    private func updatePlayerAudioState() {
        guard let playerItem = player?.currentItem else { return }
        let posMs = UInt64(timelinePosition * 1000)

        let sysClip = systemAudioClips.first(where: { posMs >= $0.timelineStartMs && posMs < $0.timelineEndMs })
        let micClip = micAudioClips.first(where: { posMs >= $0.timelineStartMs && posMs < $0.timelineEndMs })

        let audioTracks = playerItem.asset.tracks(withMediaType: .audio)
        var params: [AVMutableAudioMixInputParameters] = []

        for (index, track) in audioTracks.enumerated() {
            let p = AVMutableAudioMixInputParameters(track: track)
            let vol: Float
            if index == 0 {
                // System audio track
                if let clip = sysClip, !clip.isMuted { vol = Float(clip.volume) } else if sysClip == nil { vol = 0 } else { vol = 0 }
            } else if index == 1 {
                // Mic track
                if let clip = micClip, !clip.isMuted { vol = Float(clip.volume) } else if micClip == nil { vol = 0 } else { vol = 0 }
            } else {
                vol = 1.0
            }
            p.setVolume(vol, at: .zero)
            params.append(p)
        }

        let mix = AVMutableAudioMix()
        mix.inputParameters = params
        playerItem.audioMix = mix
    }

    private func setupPlayer(url: URL?) {
        guard let url else {
            player = nil
            return
        }
        let key = url.path
        if let cached = playerCache[key] {
            if player !== cached {
                player = cached
            }
        } else {
            let newPlayer = AVPlayer(url: url)
            newPlayer.pause()
            playerCache[key] = newPlayer
            player = newPlayer
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

extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
