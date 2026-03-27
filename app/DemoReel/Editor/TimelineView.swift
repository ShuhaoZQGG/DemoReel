import SwiftUI

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
    @State private var selection: TrackSelection = .none
    @State private var magnetedIds: Set<UUID> = []
    @State private var draggingClipId: UUID?
    @State private var dragOffset: CGFloat = 0
    @State private var scissorModeActive: Bool = false
    @State private var hoverTimelinePosition: Double? = nil
    @State private var hoveredVideoClipId: UUID? = nil
    @State private var hoveredZoomClipId: UUID? = nil
    @State private var hoveredTrack: HoveredTrack = .none
    @FocusState private var isFocused: Bool

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

    var body: some View {
        VStack(spacing: 0) {
            transportBar
            Divider()
            timelineCanvas
        }
        .background(.background)
        .onDeleteCommand { deleteSelected() }
        .onExitCommand { scissorModeActive = false }
        .onKeyPress("c") {
            scissorModeActive.toggle()
            return .handled
        }
        .onKeyPress("z") {
            onAddZoom()
            return .handled
        }
        .focusable()
        .focused($isFocused)
        .onAppear { isFocused = true }
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

            // Play / Pause
            Button(action: { isPlaying.toggle() }) {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.space, modifiers: [])

            // Go to last frame
            Button(action: {
                timelinePosition = clipManager.timelineDuration
                updateCurrentTimeFromTimeline()
            }) {
                Image(systemName: "forward.end.fill")
            }
            .buttonStyle(.plain)

            Divider().frame(height: 16)

            // Scissor mode toggle
            Button(action: { scissorModeActive.toggle() }) {
                Image(systemName: "scissors")
            }
            .buttonStyle(.plain)
            .foregroundStyle(scissorModeActive ? .blue : .primary)

            Divider().frame(height: 16)

            // Magnet: snap two selected clips adjacent
            Button(action: magnetSelected) {
                Image(systemName: "arrow.right.arrow.left")
            }
            .buttonStyle(.plain)
            .disabled(selection.count != 2)
            .help("Snap selected clips together")

            // Merge: combine magnetted adjacent clips
            Button(action: mergeSelected) {
                Image(systemName: "arrow.triangle.merge")
            }
            .buttonStyle(.plain)
            .disabled(!canMerge)
            .help("Merge magnetted clips")

            // Delete selected clips
            Button(action: deleteSelected) {
                Image(systemName: "trash")
            }
            .buttonStyle(.plain)
            .disabled(selection == .none)
            .help("Delete selected clips")

            Divider().frame(height: 16)

            // Add zoom clip at playhead
            Button(action: onAddZoom) {
                Image(systemName: "plus.circle")
            }
            .buttonStyle(.plain)
            .help("Add zoom effect at playhead (Z)")

            Divider().frame(height: 16)

            // Speed selector (video clips only)
            if case .zoomClips = selection {
                // Zoom scale selector
                Menu {
                    ForEach([1.5, 2.0, 2.5, 3.0, 4.0], id: \.self) { scale in
                        Button(String(format: "%.1fx", scale)) {
                            onZoomScaleChange(scale)
                        }
                    }
                } label: {
                    Text(String(format: "%.1fx", currentZoomScale))
                        .font(.system(.caption, design: .monospaced))
                        .frame(width: 36)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
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
                            let oldEnd = clipManager.zoomClips[idx].timelineEndMs
                            clipManager.zoomClips[idx].timelineStartMs = min(newStart, oldEnd - 100)
                            clipManager.zoomClips[idx].durationMs = oldEnd - clipManager.zoomClips[idx].timelineStartMs
                        }
                    },
                    onResizeRight: { id, newDuration in
                        if let idx = clipManager.zoomClips.firstIndex(where: { $0.id == id }) {
                            clipManager.zoomClips[idx].durationMs = max(newDuration, 100)
                        }
                    },
                    hoverTimelinePositionMs: hoverTimelinePosition.map { UInt64($0 * 1000) },
                    onScissorCut: { timelineMs in
                        clipManager.splitZoomClip(atTimelineMs: timelineMs)
                    }
                )
                .offset(y: 60)

                // Trim start handle
                TrimHandle(position: trimStart * pixelsPerSecond, side: .left, height: 160)
                    .gesture(
                        DragGesture()
                            .onChanged { value in
                                let newTime = max(0, value.location.x / pixelsPerSecond)
                                trimStart = min(newTime, trimEnd - 0.1)
                            }
                    )

                // Trim end handle
                TrimHandle(position: trimEnd * pixelsPerSecond, side: .right, height: 160)
                    .gesture(
                        DragGesture()
                            .onChanged { value in
                                let newTime = min(duration, value.location.x / pixelsPerSecond)
                                trimEnd = max(newTime, trimStart + 0.1)
                            }
                    )

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
                    if scissorModeActive {
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
                        if scissorModeActive {
                            let seconds = max(0, value.location.x / pixelsPerSecond)
                            let timelineMs = UInt64(seconds * 1000)

                            let y = value.location.y
                            if y >= 60 && y < 84 {
                                clipManager.splitZoomClip(atTimelineMs: timelineMs)
                            } else if y >= 22 && y < 52 {
                                if let (sourceMs, _) = clipManager.sourceTimeForTimelinePosition(seconds) {
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
                isHovered: scissorModeActive && hoveredVideoClipId == clip.id && hoveredTrack == .video
            )
            .offset(x: x + (isDragging ? dragOffset : 0), y: 22)
            .opacity(isDragging ? 0.6 : 1.0)
            .shadow(color: isDragging ? .black.opacity(0.3) : .clear, radius: isDragging ? 4 : 0)
            .zIndex(isDragging ? 10 : 0)
            .onTapGesture {
                if scissorModeActive, let hoverPos = hoverTimelinePosition {
                    if let (sourceMs, _) = clipManager.sourceTimeForTimelinePosition(hoverPos) {
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
                        dragOffset = value.translation.width
                    }
                    .onEnded { value in
                        let currentX = Double(clip.timelineStartMs) / 1000.0 * pixelsPerSecond
                        let newX = max(0, currentX + value.translation.width)
                        let newTimelineMs = UInt64(newX / pixelsPerSecond * 1000)
                        clipManager.moveOnTimeline(clipId: clip.id, toTimelineMs: newTimelineMs)
                        draggingClipId = nil
                        dragOffset = 0
                        magnetedIds = []
                    }
            )
        }
    }

    /// Update currentTime (source time) from the current timelinePosition.
    private func updateCurrentTimeFromTimeline() {
        if let (sourceMs, _) = clipManager.sourceTimeForTimelinePosition(timelinePosition) {
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

    private var canMerge: Bool {
        guard magnetedIds.count == 2 else { return false }
        switch selection {
        case .videoClips:
            return canMergeVideoClips
        case .zoomClips:
            return canMergeZoomClips
        case .none:
            return false
        }
    }

    private var canMergeVideoClips: Bool {
        let ids = Array(magnetedIds)
        guard let c0 = clipManager.clips.first(where: { $0.id == ids[0] }),
              let c1 = clipManager.clips.first(where: { $0.id == ids[1] }) else { return false }
        let (earlier, later) = c0.timelineStartMs <= c1.timelineStartMs ? (c0, c1) : (c1, c0)
        guard earlier.timelineEndMs == later.timelineStartMs else { return false }
        return earlier.sourceEndMs == later.sourceStartMs
    }

    private var canMergeZoomClips: Bool {
        let ids = Array(magnetedIds)
        guard let z0 = clipManager.zoomClips.first(where: { $0.id == ids[0] }),
              let z1 = clipManager.zoomClips.first(where: { $0.id == ids[1] }) else { return false }
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
        guard canMergeVideoClips else { return }
        let ids = Array(magnetedIds)
        guard let c0 = clipManager.clips.first(where: { $0.id == ids[0] }),
              let c1 = clipManager.clips.first(where: { $0.id == ids[1] }) else { return }

        let (earlier, _) = c0.timelineStartMs <= c1.timelineStartMs ? (c0, c1) : (c1, c0)
        guard let earlierIdx = clipManager.clips.firstIndex(where: { $0.id == earlier.id }) else { return }

        let laterIdx = clipManager.clips.firstIndex(where: { $0.id != earlier.id && magnetedIds.contains($0.id) })!
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
        guard canMergeZoomClips else { return }
        let ids = Array(magnetedIds)
        guard let z0 = clipManager.zoomClips.first(where: { $0.id == ids[0] }),
              let z1 = clipManager.zoomClips.first(where: { $0.id == ids[1] }) else { return }

        let (earlier, _) = z0.timelineStartMs <= z1.timelineStartMs ? (z0, z1) : (z1, z0)
        guard let earlierIdx = clipManager.zoomClips.firstIndex(where: { $0.id == earlier.id }) else { return }

        let laterIdx = clipManager.zoomClips.firstIndex(where: { $0.id != earlier.id && magnetedIds.contains($0.id) })!
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

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 4)
                .fill(fillColor)
            RoundedRectangle(cornerRadius: 4)
                .strokeBorder(borderColor, lineWidth: (isMagneted || isHovered) ? 2 : 1)
            if clip.speed != 1.0 {
                Text(speedLabel)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: width, height: 30)
    }

    private var fillColor: Color {
        if isHovered { return Color.orange.opacity(0.2) }
        if isMagneted { return Color.blue.opacity(0.2) }
        if isSelected { return Color.green.opacity(0.25) }
        return Color.gray.opacity(0.15)
    }

    private var borderColor: Color {
        if isHovered { return Color.orange }
        if isMagneted { return Color.blue }
        if isSelected { return Color.green }
        return Color.gray.opacity(0.4)
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
