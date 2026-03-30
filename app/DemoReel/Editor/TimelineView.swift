import SwiftUI

// MARK: - Tooltip Modifier

/// Custom tooltip that appears on hover, more reliable than `.help()` which is
/// disrupted by frequent SwiftUI view updates (e.g. 30 FPS playback timer).
private struct TooltipModifier: ViewModifier {
    let text: String
    @State private var isHovering = false

    func body(content: Content) -> some View {
        content
            .onHover { hovering in
                isHovering = hovering
            }
            .popover(isPresented: $isHovering, arrowEdge: .bottom) {
                Text(text)
                    .font(.caption)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .fixedSize()
                    .interactiveDismissDisabled()
            }
    }
}

extension View {
    func tooltip(_ text: String) -> some View {
        modifier(TooltipModifier(text: text))
    }
}

/// Which track the user is interacting with.
enum TrackSelection: Equatable {
    case none
    case videoClips(Set<UUID>)
    case zoomClips(Set<UUID>)

    var selectedVideoIds: Set<UUID> {
        if case .videoClips(let ids) = self { return ids }
        return []
    }

    var selectedZoomIds: Set<UUID> {
        if case .zoomClips(let ids) = self { return ids }
        return []
    }

    var count: Int {
        switch self {
        case .none: return 0
        case .videoClips(let ids): return ids.count
        case .zoomClips(let ids): return ids.count
        }
    }
}

/// Horizontal scrollable timeline with transport controls, clip track, zoom clip track,
/// trim handles, and playhead.
struct TimelineView: View {
    let duration: TimeInterval
    @Binding var currentTime: Double
    @Binding var timelinePosition: Double
    @Binding var isPlaying: Bool
    @Binding var trimStart: Double
    @Binding var trimEnd: Double
    let clipManager: ClipManager
    var onSplit: () -> Void
    var onSplitZoom: () -> Void
    var onSpeedChange: (Double) -> Void
    var onZoomScaleChange: (Double) -> Void
    var onAddZoom: () -> Void
    @State private var pixelsPerSecond: Double = 100
    @Binding var selection: TrackSelection
    @State private var magnetedIds: Set<UUID> = []
    @State private var draggingClipId: UUID?
    @State private var dragOffset: CGFloat = 0
    @Binding var scissorModeActive: Bool
    @Binding var zoomPlacementActive: Bool
    var zoomPlacementScale: Double
    var onPlaceZoom: (UInt64) -> Void
    var thumbnailCache: ThumbnailCache
    var waveformCache: WaveformCache
    @State private var hoverTimelinePosition: Double? = nil
    @State private var hoveredVideoClipId: UUID? = nil
    @State private var hoveredZoomClipId: UUID? = nil
    @State private var hoveredTrack: HoveredTrack = .none
    @State private var snappingEnabled: Bool = true
    @State private var activeSnapLineMs: UInt64? = nil

    enum HoveredTrack {
        case none, video, zoom
    }

    private var totalWidth: Double {
        max(clipManager.timelineDuration * pixelsPerSecond, duration * pixelsPerSecond, 1)
    }

    private var currentClipSpeed: Double {
        if currentTime < 0 { return 1.0 }
        let sourceMs = UInt64(currentTime * 1000)
        return clipManager.clips.first(where: { $0.sourceStartMs <= sourceMs && $0.sourceEndMs > sourceMs })?.speed ?? 1.0
    }

    private var currentZoomScale: Double {
        let posMs = UInt64(timelinePosition * 1000)
        return clipManager.zoomClips.first(where: { posMs >= $0.timelineStartMs && posMs < $0.timelineEndMs })?.scale ?? 1.0
    }

    private var selectedZoomEaseEnabled: Bool {
        guard case .zoomClips(let ids) = selection else { return false }
        return clipManager.zoomClips.filter { ids.contains($0.id) }.allSatisfy(\.easeEnabled)
    }

    private var selectedEasingCurve: String {
        guard case .zoomClips(let ids) = selection else { return "easeInOut" }
        return clipManager.zoomClips.first(where: { ids.contains($0.id) })?.easingCurve ?? "easeInOut"
    }

    private func curveLabel(_ curve: String) -> String {
        switch curve {
        case "linear": return "Linear"
        case "easeIn": return "Ease In"
        case "easeOut": return "Ease Out"
        case "easeInOut": return "Ease In Out"
        case "spring": return "Spring"
        default: return curve
        }
    }

    private func curveIcon(_ curve: String) -> String {
        switch curve {
        case "linear": return "line.diagonal"
        case "easeIn": return "arrow.up.right"
        case "easeOut": return "arrow.down.right"
        case "easeInOut": return "s.circle"
        case "spring": return "waveform.path.ecg"
        default: return "s.circle"
        }
    }

    private var snapTargets: [SnapEngine.SnapTarget] {
        SnapEngine.targets(
            playheadMs: UInt64(timelinePosition * 1000),
            clips: clipManager.clips,
            zoomClips: clipManager.zoomClips,
            trimStartMs: UInt64(trimStart * 1000),
            trimEndMs: UInt64(trimEnd * 1000)
        )
    }

    private var optionHeld: Bool {
        NSEvent.modifierFlags.contains(.option)
    }

    var body: some View {
        VStack(spacing: 0) {
            transportBar
            Divider()
            timelineCanvas
        }
        .background(.background)
        .task {
            requestAllThumbnails()
        }
        .onChange(of: clipManager.clips) {
            requestAllThumbnails()
        }
        .onChange(of: pixelsPerSecond) {
            thumbnailCache.invalidateAndRegenerate(
                clips: clipManager.clips,
                pixelsPerSecond: pixelsPerSecond,
                mediaItems: { clipManager.mediaItem(for: $0) }
            )
        }
    }

    private func requestAllThumbnails() {
        thumbnailCache.ensureThumbnails(
            clips: clipManager.clips,
            pixelsPerSecond: pixelsPerSecond,
            mediaItems: { clipManager.mediaItem(for: $0) }
        )
        waveformCache.ensureWaveforms(
            clips: clipManager.clips,
            mediaItems: { clipManager.mediaItem(for: $0) }
        )
    }

    // MARK: - Transport Bar

    private var transportBar: some View {
        HStack(spacing: 8) {
            // Go to first frame
            Button(action: {
                timelinePosition = 0
                updateCurrentTimeFromTimeline()
            }) {
                Image(systemName: "backward.end.fill")
            }
            .buttonStyle(.plain)
            .tooltip("Go to first frame")

            // Play / Pause
            Button(action: { isPlaying.toggle() }) {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.space, modifiers: [])
            .tooltip(isPlaying ? "Pause (Space)" : "Play (Space)")

            // Go to last frame
            Button(action: {
                timelinePosition = clipManager.timelineDuration
                updateCurrentTimeFromTimeline()
            }) {
                Image(systemName: "forward.end.fill")
            }
            .buttonStyle(.plain)
            .tooltip("Go to last frame")

            Divider().frame(height: 16)

            // Undo
            Button(action: { clipManager.undo() }) {
                Image(systemName: "arrow.uturn.backward")
            }
            .buttonStyle(.plain)
            .disabled(!clipManager.canUndo)
            .tooltip("Undo (\u{2318}Z)")

            // Redo
            Button(action: { clipManager.redo() }) {
                Image(systemName: "arrow.uturn.forward")
            }
            .buttonStyle(.plain)
            .disabled(!clipManager.canRedo)
            .tooltip("Redo (\u{2318}\u{21E7}Z)")

            Divider().frame(height: 16)

            // Scissor mode toggle
            Button(action: { scissorModeActive.toggle() }) {
                Image(systemName: "scissors")
            }
            .buttonStyle(.plain)
            .foregroundStyle(scissorModeActive ? .blue : .primary)
            .tooltip("Split mode (C)")

            Divider().frame(height: 16)

            // Magnet: snap two selected clips adjacent
            Button(action: magnetSelected) {
                Image(systemName: "arrow.right.arrow.left")
            }
            .buttonStyle(.plain)
            .disabled(selection.count != 2)
            .tooltip("Snap selected clips together")

            // Merge: combine magnetted adjacent clips
            Button(action: mergeSelected) {
                Image(systemName: "arrow.triangle.merge")
            }
            .buttonStyle(.plain)
            .disabled(!canMerge)
            .tooltip("Merge magnetted clips")

            // Delete selected clips
            Button(action: deleteSelected) {
                Image(systemName: "trash")
            }
            .buttonStyle(.plain)
            .disabled(selection == .none)
            .tooltip("Delete selected clips")

            Divider().frame(height: 16)

            // Add zoom clip placement mode
            Button(action: {
                zoomPlacementActive.toggle()
                if zoomPlacementActive { scissorModeActive = false }
            }) {
                Image(systemName: zoomPlacementActive ? "plus.circle.fill" : "plus.circle")
            }
            .buttonStyle(.plain)
            .foregroundStyle(zoomPlacementActive ? .green : .primary)
            .tooltip("Add zoom clip (Z)")

            Divider().frame(height: 16)

            Button(action: { snappingEnabled.toggle() }) {
                Image(systemName: snappingEnabled ? "magnet.fill" : "magnet")
            }
            .buttonStyle(.plain)
            .foregroundStyle(snappingEnabled ? .yellow : .primary)
            .tooltip("Snap to guides (\u{2325} to bypass)")

            Divider().frame(height: 16)

            // Speed selector (video clips only)
            if case .zoomClips(let ids) = selection {
                // Zoom scale slider
                Slider(
                    value: Binding(
                        get: { currentZoomScale },
                        set: { onZoomScaleChange($0) }
                    ),
                    in: 1.25...5.0,
                    step: 0.25
                )
                .frame(width: 80)
                .tooltip("Zoom scale (drag to adjust)")

                // Zoom scale preset menu
                Menu {
                    ForEach([1.25, 1.5, 2.0, 2.5, 3.0, 4.0, 5.0], id: \.self) { scale in
                        Button(String(format: "%.2fx", scale)) {
                            onZoomScaleChange(scale)
                        }
                    }
                } label: {
                    Text(String(format: "%.2fx", currentZoomScale))
                        .font(.system(.caption, design: .monospaced))
                        .frame(width: 42)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .tooltip("Zoom scale presets")

                // Ease toggle for selected zoom clips
                Button(action: {
                    for id in ids {
                        if let idx = clipManager.zoomClips.firstIndex(where: { $0.id == id }) {
                            clipManager.zoomClips[idx].easeEnabled.toggle()
                        }
                    }
                }) {
                    Image(systemName: selectedZoomEaseEnabled ? "wave.3.right.circle.fill" : "wave.3.right.circle")
                }
                .buttonStyle(.plain)
                .foregroundStyle(selectedZoomEaseEnabled ? .blue : .secondary)
                .tooltip("Toggle ease in/out")

                // Easing curve picker (only when ease is enabled)
                if selectedZoomEaseEnabled {
                    Menu {
                        ForEach(["linear", "easeIn", "easeOut", "easeInOut", "spring"], id: \.self) { curve in
                            Button(action: {
                                for id in ids {
                                    if let idx = clipManager.zoomClips.firstIndex(where: { $0.id == id }) {
                                        clipManager.zoomClips[idx].easingCurve = curve
                                    }
                                }
                            }) {
                                Label(curveLabel(curve), systemImage: curveIcon(curve))
                            }
                        }
                    } label: {
                        Image(systemName: curveIcon(selectedEasingCurve))
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .tooltip("Easing curve")
                }
            } else {
                // Video speed selector
                Menu {
                    ForEach([0.5, 1.0, 2.0, 4.0, 8.0], id: \.self) { speed in
                        Button(speedLabel(speed)) {
                            onSpeedChange(speed)
                        }
                    }
                } label: {
                    Text(speedLabel(currentClipSpeed))
                        .font(.system(.caption, design: .monospaced))
                        .frame(width: 30)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .tooltip("Playback speed")
            }

            Divider().frame(height: 16)

            // Time display (shows timeline position)
            Text(formattedTime(timelinePosition))
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(.secondary)

            Text("/")
                .foregroundStyle(.tertiary)

            Text(formattedTime(clipManager.timelineDuration))
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(.tertiary)

            Spacer()

            if trimStart > 0 || trimEnd < duration {
                Text("Trim: \(formattedTime(trimStart)) – \(formattedTime(trimEnd))")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            Spacer()

            // Timeline zoom
            HStack(spacing: 4) {
                Image(systemName: "minus.magnifyingglass")
                Slider(value: $pixelsPerSecond, in: 30...300)
                    .frame(width: 100)
                Image(systemName: "plus.magnifyingglass")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .tooltip("Timeline zoom")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    // MARK: - Timeline Canvas

    private var timelineCanvas: some View {
        ScrollView(.horizontal, showsIndicators: true) {
            ZStack(alignment: .topLeading) {
                // Time ruler
                TimeRuler(duration: clipManager.timelineDuration, pixelsPerSecond: pixelsPerSecond)
                    .frame(height: 20)

                // Video clip track (y: 22)
                clipTrack

                // Zoom clip track (y: 60)
                ZoomClipTrack(
                    clipManager: clipManager,
                    pixelsPerSecond: pixelsPerSecond,
                    trackHeight: 24,
                    isTrackSelected: selection.selectedZoomIds.count > 0,
                    selectedZoomClipIds: selection.selectedZoomIds,
                    magnetedZoomClipIds: magnetedIdsForZoom,
                    hoveredZoomClipId: hoveredTrack == .zoom ? hoveredZoomClipId : nil,
                    scissorModeActive: scissorModeActive,
                    onSelect: { id, isCmd in handleZoomSelect(id: id, isCmd: isCmd) },
                    onDragMove: { id, ms in
                        clipManager.moveZoomClipOnTimeline(clipId: id, toTimelineMs: ms)
                        magnetedIds = []
                    },
                    onResizeLeft: { id, newStart in
                        if let idx = clipManager.zoomClips.firstIndex(where: { $0.id == id }) {
                            clipManager.saveUndoState()
                            let oldEnd = clipManager.zoomClips[idx].timelineEndMs
                            clipManager.zoomClips[idx].timelineStartMs = min(newStart, oldEnd - 100)
                            clipManager.zoomClips[idx].durationMs = oldEnd - clipManager.zoomClips[idx].timelineStartMs
                        }
                    },
                    onResizeRight: { id, newDuration in
                        if let idx = clipManager.zoomClips.firstIndex(where: { $0.id == id }) {
                            clipManager.saveUndoState()
                            clipManager.zoomClips[idx].durationMs = max(newDuration, 100)
                        }
                    },
                    onResizeEaseIn: { id, newEaseInMs in
                        if let idx = clipManager.zoomClips.firstIndex(where: { $0.id == id }) {
                            clipManager.saveUndoState()
                            clipManager.zoomClips[idx].easeInMs = newEaseInMs
                        }
                    },
                    onResizeEaseOut: { id, newEaseOutMs in
                        if let idx = clipManager.zoomClips.firstIndex(where: { $0.id == id }) {
                            clipManager.saveUndoState()
                            clipManager.zoomClips[idx].easeOutMs = newEaseOutMs
                        }
                    },
                    onScaleChange: { id, newScale in
                        clipManager.saveUndoStateDebounced()
                        if let idx = clipManager.zoomClips.firstIndex(where: { $0.id == id }) {
                            clipManager.zoomClips[idx].scale = newScale
                        }
                    },
                    hoverTimelinePositionMs: hoverTimelinePosition.map { UInt64($0 * 1000) },
                    onScissorCut: { timelineMs in
                        clipManager.splitZoomClip(atTimelineMs: timelineMs)
                    },
                    snapTargets: snapTargets,
                    snappingEnabled: snappingEnabled,
                    activeSnapLineMs: $activeSnapLineMs
                )
                .offset(y: 60)

                // Trim start handle
                TrimHandle(position: trimStart * pixelsPerSecond, side: .left, height: 160)
                    .gesture(
                        DragGesture()
                            .onChanged { value in
                                var newTime = max(0, value.location.x / pixelsPerSecond)
                                if snappingEnabled && !optionHeld {
                                    let proposedMs = UInt64(newTime * 1000)
                                    if let snapped = SnapEngine.snap(proposedMs: proposedMs, targets: snapTargets, thresholdPx: 8, pixelsPerSecond: pixelsPerSecond, excludeMs: [UInt64(trimStart * 1000)]) {
                                        newTime = Double(snapped) / 1000.0
                                        activeSnapLineMs = snapped
                                    } else {
                                        activeSnapLineMs = nil
                                    }
                                }
                                trimStart = min(newTime, trimEnd - 0.1)
                            }
                            .onEnded { _ in activeSnapLineMs = nil }
                    )

                // Trim end handle
                TrimHandle(position: trimEnd * pixelsPerSecond, side: .right, height: 160)
                    .gesture(
                        DragGesture()
                            .onChanged { value in
                                var newTime = min(duration, value.location.x / pixelsPerSecond)
                                if snappingEnabled && !optionHeld {
                                    let proposedMs = UInt64(newTime * 1000)
                                    if let snapped = SnapEngine.snap(proposedMs: proposedMs, targets: snapTargets, thresholdPx: 8, pixelsPerSecond: pixelsPerSecond, excludeMs: [UInt64(trimEnd * 1000)]) {
                                        newTime = Double(snapped) / 1000.0
                                        activeSnapLineMs = snapped
                                    } else {
                                        activeSnapLineMs = nil
                                    }
                                }
                                trimEnd = max(newTime, trimStart + 0.1)
                            }
                            .onEnded { _ in activeSnapLineMs = nil }
                    )

                // Snap guide line
                if let snapMs = activeSnapLineMs {
                    let snapX = Double(snapMs) / 1000.0 * pixelsPerSecond
                    Rectangle()
                        .fill(Color.yellow.opacity(0.8))
                        .frame(width: 1, height: 160)
                        .offset(x: snapX, y: 0)
                        .allowsHitTesting(false)
                }

                // Playhead
                Rectangle()
                    .fill(.red)
                    .frame(width: 1.5, height: 160)
                    .offset(x: timelinePosition * pixelsPerSecond)
                    .allowsHitTesting(false)

                // Scissor cut line + icon (shown in scissor mode while hovering)
                if scissorModeActive, let hoverPos = hoverTimelinePosition {
                    Rectangle()
                        .fill(Color.blue.opacity(0.8))
                        .frame(width: 1.5, height: 160)
                        .offset(x: hoverPos * pixelsPerSecond)
                        .allowsHitTesting(false)
                    Image(systemName: "scissors")
                        .font(.system(size: 10))
                        .foregroundStyle(.blue)
                        .offset(x: hoverPos * pixelsPerSecond - 5, y: 6)
                        .allowsHitTesting(false)
                }

                // Zoom placement shadow (shown in placement mode while hovering)
                if zoomPlacementActive, let hoverPos = hoverTimelinePosition {
                    let shadowWidth = 1.0 * pixelsPerSecond // 1 second duration
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.green.opacity(0.3))
                        .stroke(Color.green.opacity(0.8), lineWidth: 1.5)
                        .frame(width: shadowWidth, height: 24)
                        .offset(x: hoverPos * pixelsPerSecond, y: 60)
                        .allowsHitTesting(false)
                    Text(String(format: "%.1fx", zoomPlacementScale))
                        .font(.system(size: 9))
                        .foregroundStyle(.green)
                        .offset(x: hoverPos * pixelsPerSecond + shadowWidth / 2, y: 60 + 12)
                        .allowsHitTesting(false)
                }
            }
            .frame(width: totalWidth, height: 160)
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let location):
                    let seconds = max(0, location.x / pixelsPerSecond)
                    hoverTimelinePosition = seconds

                    // Determine hovered track by Y position
                    if location.y >= 22 && location.y < 52 {
                        hoveredTrack = .video
                    } else if location.y >= 60 && location.y < 84 {
                        hoveredTrack = .zoom
                    } else {
                        hoveredTrack = .none
                    }

                    // Determine which clips are hovered
                    let posMs = UInt64(seconds * 1000)
                    hoveredVideoClipId = clipManager.clips.first(where: { posMs >= $0.timelineStartMs && posMs < $0.timelineEndMs })?.id
                    hoveredZoomClipId = clipManager.zoomClips.first(where: { posMs >= $0.timelineStartMs && posMs < $0.timelineEndMs })?.id

                    // Scrub preview to hover position (only when not playing)
                    if !isPlaying {
                        timelinePosition = seconds
                        updateCurrentTimeFromTimeline()
                    }

                    // Cursor
                    if scissorModeActive || zoomPlacementActive {
                        NSCursor.crosshair.set()
                    }
                case .ended:
                    hoverTimelinePosition = nil
                    hoveredVideoClipId = nil
                    hoveredZoomClipId = nil
                    hoveredTrack = .none
                    NSCursor.arrow.set()
                @unknown default:
                    break
                }
            }
            .gesture(
                SpatialTapGesture()
                    .onEnded { value in
                        let seconds = max(0, value.location.x / pixelsPerSecond)
                        let timelineMs = UInt64(seconds * 1000)

                        if zoomPlacementActive {
                            onPlaceZoom(timelineMs)
                            zoomPlacementActive = false
                        } else if scissorModeActive {
                            let y = value.location.y
                            if y >= 60 && y < 84 {
                                clipManager.splitZoomClip(atTimelineMs: timelineMs)
                            } else if y >= 22 && y < 52 {
                                if let (sourceMs, _, _) = clipManager.sourceTimeForTimelinePosition(seconds) {
                                    clipManager.split(atSourceTimeMs: sourceMs)
                                }
                            }
                        }
                    }
            )
        }
    }

    // MARK: - Video Clip Track

    private var clipTrack: some View {
        ForEach(Array(clipManager.clips.enumerated()), id: \.element.id) { index, clip in
            let x = Double(clip.timelineStartMs) / 1000.0 * pixelsPerSecond
            let width = clip.sourceDuration * pixelsPerSecond
            let isDragging = clip.id == draggingClipId

            ClipSegmentView(
                clip: clip,
                width: max(width, 4),
                isSelected: selection.selectedVideoIds.contains(clip.id),
                isMagneted: magnetedIdsForVideo.contains(clip.id),
                isHovered: scissorModeActive && hoveredVideoClipId == clip.id && hoveredTrack == .video,
                sourceName: clipManager.mediaItem(for: clip)?.name,
                sourceColor: colorForMediaItem(clip.mediaItemId),
                thumbnails: thumbnailCache.thumbnails(for: clip, pixelsPerSecond: pixelsPerSecond, mediaItem: clipManager.mediaItem(for: clip)),
                waveformSamples: waveformCache.waveformSamples(for: clip, pixelsPerSecond: pixelsPerSecond, mediaItem: clipManager.mediaItem(for: clip))
            )
            .offset(x: x + (isDragging ? dragOffset : 0), y: 22)
            .opacity(isDragging ? 0.6 : 1.0)
            .shadow(color: isDragging ? .black.opacity(0.3) : .clear, radius: isDragging ? 4 : 0)
            .zIndex(isDragging ? 10 : 0)
            .onTapGesture {
                if scissorModeActive, let hoverPos = hoverTimelinePosition {
                    if let (sourceMs, _, _) = clipManager.sourceTimeForTimelinePosition(hoverPos) {
                        clipManager.split(atSourceTimeMs: sourceMs)
                    }
                } else {
                    let isCmd = NSEvent.modifierFlags.contains(.command)
                    handleVideoSelect(id: clip.id, isCmd: isCmd)
                }
            }
            .highPriorityGesture(
                DragGesture(minimumDistance: 5)
                    .onChanged { value in
                        draggingClipId = clip.id
                        let currentX = Double(clip.timelineStartMs) / 1000.0 * pixelsPerSecond
                        let proposedX = max(0, currentX + value.translation.width)
                        let proposedMs = UInt64(proposedX / pixelsPerSecond * 1000)

                        if snappingEnabled && !optionHeld {
                            let exclude: Set<UInt64> = [clip.timelineStartMs, clip.timelineEndMs]
                            if let snapped = SnapEngine.snap(proposedMs: proposedMs, targets: snapTargets, thresholdPx: 8, pixelsPerSecond: pixelsPerSecond, excludeMs: exclude) {
                                let snappedX = Double(snapped) / 1000.0 * pixelsPerSecond
                                dragOffset = snappedX - currentX
                                activeSnapLineMs = snapped
                            } else {
                                dragOffset = value.translation.width
                                activeSnapLineMs = nil
                            }
                        } else {
                            dragOffset = value.translation.width
                            activeSnapLineMs = nil
                        }
                    }
                    .onEnded { _ in
                        let currentX = Double(clip.timelineStartMs) / 1000.0 * pixelsPerSecond
                        let newX = max(0, currentX + dragOffset)
                        let newTimelineMs = UInt64(newX / pixelsPerSecond * 1000)
                        clipManager.moveOnTimeline(clipId: clip.id, toTimelineMs: newTimelineMs)
                        draggingClipId = nil
                        dragOffset = 0
                        magnetedIds = []
                        activeSnapLineMs = nil
                    }
            )
        }
    }

    /// Assign a stable color to each media source for visual distinction on the timeline.
    private func colorForMediaItem(_ mediaItemId: UUID?) -> Color {
        guard let id = mediaItemId else { return Color.gray }
        let colors: [Color] = [.blue, .purple, .teal, .indigo, .mint, .cyan, .pink, .orange]
        guard let index = clipManager.mediaItems.firstIndex(where: { $0.id == id }) else { return .gray }
        return colors[index % colors.count]
    }

    /// Update currentTime (source time) from the current timelinePosition.
    private func updateCurrentTimeFromTimeline() {
        if let (sourceMs, _, _) = clipManager.sourceTimeForTimelinePosition(timelinePosition) {
            currentTime = Double(sourceMs) / 1000.0
        } else {
            currentTime = -1
        }
    }

    // MARK: - Selection Helpers

    private func handleVideoSelect(id: UUID, isCmd: Bool) {
        if isCmd, case .videoClips(var ids) = selection {
            if ids.contains(id) { ids.remove(id) } else if ids.count < 2 { ids.insert(id) }
            selection = ids.isEmpty ? .none : .videoClips(ids)
        } else {
            selection = .videoClips([id])
        }
        magnetedIds = []
    }

    private func handleZoomSelect(id: UUID, isCmd: Bool) {
        if isCmd, case .zoomClips(var ids) = selection {
            if ids.contains(id) { ids.remove(id) } else if ids.count < 2 { ids.insert(id) }
            selection = ids.isEmpty ? .none : .zoomClips(ids)
        } else {
            selection = .zoomClips([id])
        }
        magnetedIds = []
    }

    private var magnetedIdsForVideo: Set<UUID> {
        if case .videoClips = selection { return magnetedIds }
        return []
    }

    private var magnetedIdsForZoom: Set<UUID> {
        if case .zoomClips = selection { return magnetedIds }
        return []
    }

    // MARK: - Split

    private func handleSplit() {
        switch selection {
        case .zoomClips:
            onSplitZoom()
        default:
            onSplit()
        }
        magnetedIds = []
    }

    // MARK: - Delete

    private func deleteSelected() {
        switch selection {
        case .videoClips(let ids):
            clipManager.deleteClips(ids: ids)
        case .zoomClips(let ids):
            clipManager.deleteZoomClips(ids: ids)
        case .none:
            break
        }
        selection = .none
        magnetedIds = []
    }

    // MARK: - Magnet & Merge

    private func magnetSelected() {
        switch selection {
        case .videoClips(let ids):
            magnetVideoClips(ids: ids)
        case .zoomClips(let ids):
            magnetZoomClips(ids: ids)
        case .none:
            break
        }
    }

    private func magnetVideoClips(ids: Set<UUID>) {
        let idArray = Array(ids)
        guard idArray.count == 2 else { return }
        guard let clip0 = clipManager.clips.first(where: { $0.id == idArray[0] }),
              let clip1 = clipManager.clips.first(where: { $0.id == idArray[1] }) else { return }

        let (earlier, later) = clip0.timelineStartMs <= clip1.timelineStartMs ? (clip0, clip1) : (clip1, clip0)
        if let laterIdx = clipManager.clips.firstIndex(where: { $0.id == later.id }) {
            clipManager.clips[laterIdx].timelineStartMs = earlier.timelineEndMs
        }
        magnetedIds = ids
    }

    private func magnetZoomClips(ids: Set<UUID>) {
        let idArray = Array(ids)
        guard idArray.count == 2 else { return }
        guard let zc0 = clipManager.zoomClips.first(where: { $0.id == idArray[0] }),
              let zc1 = clipManager.zoomClips.first(where: { $0.id == idArray[1] }) else { return }

        let (earlier, later) = zc0.timelineStartMs <= zc1.timelineStartMs ? (zc0, zc1) : (zc1, zc0)
        if let laterIdx = clipManager.zoomClips.firstIndex(where: { $0.id == later.id }) {
            clipManager.zoomClips[laterIdx].timelineStartMs = earlier.timelineEndMs
        }
        magnetedIds = ids
    }

    /// IDs of the two clips eligible for merge — either explicitly magnetted or already adjacent when selected.
    private var mergeableIds: Set<UUID> {
        if magnetedIds.count == 2 { return magnetedIds }
        // Also allow merge when 2 selected clips are already adjacent
        switch selection {
        case .videoClips(let ids) where ids.count == 2:
            return ids
        case .zoomClips(let ids) where ids.count == 2:
            return ids
        default:
            return []
        }
    }

    private var canMerge: Bool {
        let ids = mergeableIds
        guard ids.count == 2 else { return false }
        switch selection {
        case .videoClips:
            return canMergeVideoClips(ids)
        case .zoomClips:
            return canMergeZoomClips(ids)
        case .none:
            return false
        }
    }

    private func canMergeVideoClips(_ ids: Set<UUID>) -> Bool {
        let idArr = Array(ids)
        guard let c0 = clipManager.clips.first(where: { $0.id == idArr[0] }),
              let c1 = clipManager.clips.first(where: { $0.id == idArr[1] }) else { return false }
        let (earlier, later) = c0.timelineStartMs <= c1.timelineStartMs ? (c0, c1) : (c1, c0)
        guard earlier.timelineEndMs == later.timelineStartMs else { return false }
        return earlier.sourceEndMs == later.sourceStartMs
    }

    private func canMergeZoomClips(_ ids: Set<UUID>) -> Bool {
        let idArr = Array(ids)
        guard let z0 = clipManager.zoomClips.first(where: { $0.id == idArr[0] }),
              let z1 = clipManager.zoomClips.first(where: { $0.id == idArr[1] }) else { return false }
        let (earlier, later) = z0.timelineStartMs <= z1.timelineStartMs ? (z0, z1) : (z1, z0)
        return earlier.timelineEndMs == later.timelineStartMs
    }

    private func mergeSelected() {
        switch selection {
        case .videoClips:
            mergeVideoClips()
        case .zoomClips:
            mergeZoomClips()
        case .none:
            break
        }
    }

    private func mergeVideoClips() {
        let mIds = mergeableIds
        guard canMergeVideoClips(mIds) else { return }
        let idArr = Array(mIds)
        guard let c0 = clipManager.clips.first(where: { $0.id == idArr[0] }),
              let c1 = clipManager.clips.first(where: { $0.id == idArr[1] }) else { return }

        let (earlier, _) = c0.timelineStartMs <= c1.timelineStartMs ? (c0, c1) : (c1, c0)
        guard let earlierIdx = clipManager.clips.firstIndex(where: { $0.id == earlier.id }) else { return }

        let laterIdx = clipManager.clips.firstIndex(where: { $0.id != earlier.id && mIds.contains($0.id) })!
        if laterIdx != earlierIdx + 1 {
            let laterClip = clipManager.clips.remove(at: laterIdx)
            let insertAt = laterIdx > earlierIdx ? earlierIdx + 1 : earlierIdx
            clipManager.clips.insert(laterClip, at: insertAt)
        }

        let mergeIdx = clipManager.clips.firstIndex(where: { $0.id == earlier.id })!
        clipManager.merge(clipIndex: mergeIdx)
        magnetedIds = []
        selection = .none
    }

    private func mergeZoomClips() {
        let mIds = mergeableIds
        guard canMergeZoomClips(mIds) else { return }
        let idArr = Array(mIds)
        guard let z0 = clipManager.zoomClips.first(where: { $0.id == idArr[0] }),
              let z1 = clipManager.zoomClips.first(where: { $0.id == idArr[1] }) else { return }

        let (earlier, _) = z0.timelineStartMs <= z1.timelineStartMs ? (z0, z1) : (z1, z0)
        guard let earlierIdx = clipManager.zoomClips.firstIndex(where: { $0.id == earlier.id }) else { return }

        let laterIdx = clipManager.zoomClips.firstIndex(where: { $0.id != earlier.id && mIds.contains($0.id) })!
        if laterIdx != earlierIdx + 1 {
            let laterClip = clipManager.zoomClips.remove(at: laterIdx)
            let insertAt = laterIdx > earlierIdx ? earlierIdx + 1 : earlierIdx
            clipManager.zoomClips.insert(laterClip, at: insertAt)
        }

        let mergeIdx = clipManager.zoomClips.firstIndex(where: { $0.id == earlier.id })!
        clipManager.mergeZoomClips(leftIndex: mergeIdx)
        magnetedIds = []
        selection = .none
    }

    // MARK: - Helpers

    private func speedLabel(_ speed: Double) -> String {
        if speed == 0.5 { return "0.5x" }
        if speed == 1.0 { return "1x" }
        return "\(Int(speed))x"
    }

    private func formattedTime(_ time: Double) -> String {
        let t = max(0, time)
        let minutes = Int(t) / 60
        let seconds = Int(t) % 60
        let millis = Int((t.truncatingRemainder(dividingBy: 1)) * 10)
        return String(format: "%02d:%02d.%01d", minutes, seconds, millis)
    }
}

// MARK: - Clip Segment View

/// Renders a single clip as a rounded rectangle on the clip track.
struct ClipSegmentView: View {
    let clip: Clip
    let width: Double
    let isSelected: Bool
    let isMagneted: Bool
    var isHovered: Bool = false
    var sourceName: String? = nil
    var sourceColor: Color = Color.gray.opacity(0.15)
    var thumbnails: [NSImage] = []
    var waveformSamples: [Float] = []

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 4)
                .fill(fillColor)

            if !waveformSamples.isEmpty {
                Canvas { context, size in
                    let midY = size.height / 2
                    let step = size.width / Double(waveformSamples.count)
                    var path = Path()
                    for (i, sample) in waveformSamples.enumerated() {
                        let x = Double(i) * step
                        let amp = Double(sample) * midY * 0.85
                        path.addRect(CGRect(x: x, y: midY - amp, width: max(step, 1), height: amp * 2))
                    }
                    context.fill(path, with: .color(.white.opacity(0.35)))
                }
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .allowsHitTesting(false)
            }

            if !thumbnails.isEmpty {
                let thumbWidth = width / Double(thumbnails.count)
                HStack(spacing: 0) {
                    ForEach(Array(thumbnails.enumerated()), id: \.offset) { _, thumb in
                        Image(nsImage: thumb)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: thumbWidth, height: 30)
                            .clipped()
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .opacity(0.6)
            }

            RoundedRectangle(cornerRadius: 4)
                .strokeBorder(borderColor, lineWidth: (isMagneted || isHovered) ? 2 : 1)
            VStack(spacing: 1) {
                if let name = sourceName {
                    Text(name)
                        .font(.system(size: 8))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                if clip.speed != 1.0 {
                    Text(speedLabel)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 2)
        }
        .frame(width: width, height: 30)
    }

    private var fillColor: Color {
        if isHovered { return Color.orange.opacity(0.2) }
        if isMagneted { return Color.blue.opacity(0.2) }
        if isSelected { return Color.green.opacity(0.25) }
        return sourceColor.opacity(0.2)
    }

    private var borderColor: Color {
        if isHovered { return Color.orange }
        if isMagneted { return Color.blue }
        if isSelected { return Color.green }
        return sourceColor.opacity(0.6)
    }

    private var speedLabel: String {
        if clip.speed == 0.5 { return "0.5x" }
        if clip.speed == 1.0 { return "" }
        return "\(Int(clip.speed))x"
    }
}

// MARK: - Trim Handle

/// Draggable trim handle on the timeline.
struct TrimHandle: View {
    let position: Double
    enum Side { case left, right }
    let side: Side
    var height: Double = 100

    var body: some View {
        ZStack {
            Rectangle()
                .fill(.orange)
                .frame(width: 3)

            VStack {
                Image(systemName: side == .left ? "chevron.compact.right" : "chevron.compact.left")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 14, height: 28)
                    .background(.orange, in: RoundedRectangle(cornerRadius: 3))
                Spacer()
            }
        }
        .frame(width: 14, height: height)
        .offset(x: position - 7)
        .contentShape(Rectangle())
    }
}

// MARK: - Time Ruler

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
