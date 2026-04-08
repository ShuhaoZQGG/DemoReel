import SwiftUI

/// Renders and edits zoom clips on the timeline's zoom track.
/// Supports drag to move, edge-resize, ease-in/out resize, selection, and displays scale label.
struct ZoomClipTrack: View {
    let clipManager: ClipManager
    let pixelsPerSecond: Double
    let trackHeight: Double
    let isTrackSelected: Bool
    let selectedZoomClipIds: Set<UUID>
    let magnetedZoomClipIds: Set<UUID>
    var hoveredZoomClipId: UUID? = nil
    var scissorModeActive: Bool = false
    var flashingClipIds: Set<UUID> = []
    var onSelect: (UUID, Bool) -> Void
    var onDragMove: (UUID, UInt64) -> Void
    var onResizeLeft: (UUID, UInt64) -> Void
    var onResizeRight: (UUID, UInt64) -> Void
    var onResizeEaseIn: (UUID, UInt64) -> Void
    var onResizeEaseOut: (UUID, UInt64) -> Void
    var onScaleChange: (UUID, Double) -> Void
    var hoverTimelinePositionMs: UInt64? = nil
    var onScissorCut: ((UInt64) -> Void)? = nil
    var snapTargets: [SnapEngine.SnapTarget] = []
    var snappingEnabled: Bool = false
    var thumbnailCache: ThumbnailCache
    @Binding var activeSnapLineMs: UInt64?

    @State private var previewClipId: UUID? = nil
    @State private var previewImage: NSImage? = nil
    @State private var previewZoomClip: ZoomClip? = nil
    @State private var previewVideoWidth: Double = 0
    @State private var previewVideoHeight: Double = 0
    @State private var previewTask: Task<Void, Never>? = nil

    @State private var draggingId: UUID?
    @State private var dragOffset: Double = 0
    @State private var resizingEdge: ResizeEdge?
    @State private var resizeOffset: Double = 0
    @State private var hoveredEdge: HoveredEdge = .none

    enum GestureMode: Equatable {
        case undecided(UUID)
        case horizontal
        case verticalScale(UUID)
    }

    @State private var gestureMode: GestureMode? = nil
    @State private var scaleBeforeDrag: Double = 1.0
    @State private var liveScale: Double? = nil

    enum ResizeEdge {
        case left(UUID)
        case right(UUID)
        case easeIn(UUID)
        case easeOut(UUID)
    }

    enum HoveredEdge: Equatable {
        case none
        case leftEdge(UUID)
        case rightEdge(UUID)
        case easeInEdge(UUID)
        case easeOutEdge(UUID)
    }

    private let edgeHitZone: Double = 10
    private let easeEdgeHitZone: Double = 6

    var body: some View {
        ZStack(alignment: .leading) {
            ForEach(clipManager.zoomClips) { zc in
                let x = Double(zc.timelineStartMs) / 1000.0 * pixelsPerSecond
                let width = zc.timelineDuration * pixelsPerSecond
                let isDragging = zc.id == draggingId
                let isSelected = selectedZoomClipIds.contains(zc.id)
                let isMagneted = magnetedZoomClipIds.contains(zc.id)

                let (visualX, visualWidth) = resizeVisuals(for: zc, baseX: x, baseWidth: width)

                ZoomClipView(
                    zoomClip: zc,
                    width: max(visualWidth, 8),
                    isSelected: isSelected,
                    isMagneted: isMagneted,
                    isHovered: scissorModeActive && hoveredZoomClipId == zc.id,
                    leftEdgeHighlighted: hoveredEdge == .leftEdge(zc.id),
                    rightEdgeHighlighted: hoveredEdge == .rightEdge(zc.id),
                    easeInEdgeHighlighted: hoveredEdge == .easeInEdge(zc.id),
                    easeOutEdgeHighlighted: hoveredEdge == .easeOutEdge(zc.id),
                    easeInResizeOffset: easeInResizeVisualOffset(for: zc),
                    easeOutResizeOffset: easeOutResizeVisualOffset(for: zc),
                    isFlashing: flashingClipIds.contains(zc.id),
                    isScaleDragging: gestureMode == .verticalScale(zc.id),
                    liveScale: gestureMode == .verticalScale(zc.id) ? liveScale : nil
                )
                .onContinuousHover { phase in
                    // Skip hover tracking during drag to avoid expensive cursor/redraw calls
                    guard gestureMode == nil else { return }
                    switch phase {
                    case .active(let location):
                        let clipWidth = max(visualWidth, 8)
                        let easeInWidth = zc.easeEnabled ? zc.easeInFraction * clipWidth : 0
                        let easeOutWidth = zc.easeEnabled ? zc.easeOutFraction * clipWidth : 0

                        if location.x < edgeHitZone {
                            hoveredEdge = .leftEdge(zc.id)
                            NSCursor.resizeLeftRight.set()
                            cancelPreview()
                        } else if location.x > clipWidth - edgeHitZone {
                            hoveredEdge = .rightEdge(zc.id)
                            NSCursor.resizeLeftRight.set()
                            cancelPreview()
                        } else if zc.easeEnabled && abs(location.x - easeInWidth) < easeEdgeHitZone {
                            hoveredEdge = .easeInEdge(zc.id)
                            NSCursor.resizeLeftRight.set()
                            cancelPreview()
                        } else if zc.easeEnabled && abs(location.x - (clipWidth - easeOutWidth)) < easeEdgeHitZone {
                            hoveredEdge = .easeOutEdge(zc.id)
                            NSCursor.resizeLeftRight.set()
                            cancelPreview()
                        } else {
                            hoveredEdge = .none
                            NSCursor.arrow.set()
                            if !scissorModeActive {
                                startPreviewTimer(for: zc)
                            }
                        }
                    case .ended:
                        if hoveredEdge != .none {
                            hoveredEdge = .none
                            NSCursor.arrow.set()
                        }
                        cancelPreview()
                    @unknown default:
                        break
                    }
                }
                .popover(isPresented: Binding(get: { previewClipId == zc.id }, set: { if !$0 { cancelPreview() } }), arrowEdge: .top) {
                    ZoomPreviewPopover(
                        image: previewImage,
                        scale: zc.scale,
                        centerX: zc.centerX,
                        centerY: zc.centerY,
                        videoWidth: previewVideoWidth,
                        videoHeight: previewVideoHeight
                    )
                }
                .onTapGesture {
                    if scissorModeActive, let cut = onScissorCut, let posMs = hoverTimelinePositionMs {
                        cut(posMs)
                    } else {
                        let isCmd = NSEvent.modifierFlags.contains(.command)
                        onSelect(zc.id, isCmd)
                    }
                }
                .highPriorityGesture(
                    DragGesture(minimumDistance: 3)
                        .onChanged { value in
                            cancelPreview()
                            if gestureMode == nil {
                                // First event: detect edge zones immediately, center zone defers
                                let localX = value.startLocation.x
                                let clipWidth = max(visualWidth, 8)
                                let easeInWidth = zc.easeEnabled ? zc.easeInFraction * clipWidth : 0
                                let easeOutWidth = zc.easeEnabled ? zc.easeOutFraction * clipWidth : 0

                                if localX < edgeHitZone {
                                    resizingEdge = .left(zc.id)
                                    gestureMode = .horizontal
                                } else if localX > clipWidth - edgeHitZone {
                                    resizingEdge = .right(zc.id)
                                    gestureMode = .horizontal
                                } else if zc.easeEnabled && abs(localX - easeInWidth) < easeEdgeHitZone {
                                    resizingEdge = .easeIn(zc.id)
                                    gestureMode = .horizontal
                                } else if zc.easeEnabled && abs(localX - (clipWidth - easeOutWidth)) < easeEdgeHitZone {
                                    resizingEdge = .easeOut(zc.id)
                                    gestureMode = .horizontal
                                } else {
                                    gestureMode = .undecided(zc.id)
                                }
                            }

                            // Resolve undecided mode based on dominant drag direction
                            if case .undecided(let id) = gestureMode {
                                let dx = abs(value.translation.width)
                                let dy = abs(value.translation.height)
                                if dx > 5 {
                                    gestureMode = .horizontal
                                    draggingId = id
                                } else if dy > 5 {
                                    gestureMode = .verticalScale(id)
                                    scaleBeforeDrag = zc.scale
                                    NSCursor.resizeUpDown.set()
                                } else {
                                    return // not enough movement to decide yet
                                }
                            }

                            // Handle vertical scale drag
                            if case .verticalScale(let id) = gestureMode, id == zc.id {
                                let rawScale = scaleBeforeDrag - (value.translation.height / 150.0) * 3.75
                                let clamped = min(5.0, max(1.25, rawScale))
                                let quantized = (clamped * 4).rounded() / 4
                                liveScale = quantized
                                onScaleChange(id, quantized)
                                return
                            }

                            let canSnap = snappingEnabled && !NSEvent.modifierFlags.contains(.option)

                            if resizingEdge != nil {
                                resizeOffset = value.translation.width
                            } else if draggingId != nil {
                                let currentX = Double(zc.timelineStartMs) / 1000.0 * pixelsPerSecond
                                let proposedX = max(0, currentX + value.translation.width)
                                let proposedMs = UInt64(proposedX / pixelsPerSecond * 1000)

                                if canSnap {
                                    let exclude: Set<UInt64> = [zc.timelineStartMs, zc.timelineEndMs]
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
                        }
                        .onEnded { _ in
                            if case .verticalScale = gestureMode {
                                NSCursor.arrow.set()
                            } else if let edge = resizingEdge {
                                applyResize(edge: edge, zoomClip: zc, offset: resizeOffset)
                            } else if draggingId != nil {
                                let currentX = Double(zc.timelineStartMs) / 1000.0 * pixelsPerSecond
                                let newX = max(0, currentX + dragOffset)
                                let newMs = UInt64(newX / pixelsPerSecond * 1000)
                                onDragMove(zc.id, newMs)
                            }
                            draggingId = nil
                            dragOffset = 0
                            resizingEdge = nil
                            resizeOffset = 0
                            gestureMode = nil
                            liveScale = nil
                            activeSnapLineMs = nil
                        }
                )
                .offset(x: visualX + (isDragging ? dragOffset : 0))
                .animation(nil, value: dragOffset)
                .opacity(isDragging ? 0.6 : 1.0)
                .zIndex(isDragging ? 10 : 0)
            }
        }
    }

    private func resizeVisuals(for zc: ZoomClip, baseX: Double, baseWidth: Double) -> (Double, Double) {
        guard let edge = resizingEdge else { return (baseX, baseWidth) }
        switch edge {
        case .left(let id) where id == zc.id:
            let newX = baseX + resizeOffset
            let newWidth = baseWidth - resizeOffset
            return (newX, max(newWidth, 8))
        case .right(let id) where id == zc.id:
            let newWidth = baseWidth + resizeOffset
            return (baseX, max(newWidth, 8))
        default:
            return (baseX, baseWidth)
        }
    }

    /// Visual offset for ease-in boundary during drag (pixels, positive = wider ease-in)
    private func easeInResizeVisualOffset(for zc: ZoomClip) -> Double {
        guard case .easeIn(let id) = resizingEdge, id == zc.id else { return 0 }
        return resizeOffset
    }

    /// Visual offset for ease-out boundary during drag (pixels, positive = wider ease-out)
    private func easeOutResizeVisualOffset(for zc: ZoomClip) -> Double {
        guard case .easeOut(let id) = resizingEdge, id == zc.id else { return 0 }
        return -resizeOffset // negate: dragging left (negative) should grow the region
    }

    private func applyResize(edge: ResizeEdge, zoomClip: ZoomClip, offset: Double) {
        let deltaMs = Int64(offset / pixelsPerSecond * 1000)
        let minDurationMs: UInt64 = 100
        let canSnap = snappingEnabled && !NSEvent.modifierFlags.contains(.option)

        switch edge {
        case .left(let id):
            let newStart = max(0, Int64(zoomClip.timelineStartMs) + deltaMs)
            let maxStart = Int64(zoomClip.timelineEndMs) - Int64(minDurationMs)
            var clampedStart = UInt64(min(newStart, maxStart))
            if canSnap, let snapped = SnapEngine.snap(proposedMs: clampedStart, targets: snapTargets, thresholdPx: 8, pixelsPerSecond: pixelsPerSecond, excludeMs: [zoomClip.timelineStartMs]) {
                clampedStart = min(snapped, UInt64(maxStart))
            }
            onResizeLeft(id, clampedStart)

        case .right(let id):
            let newEnd = max(Int64(zoomClip.timelineStartMs) + Int64(minDurationMs),
                           Int64(zoomClip.timelineEndMs) + deltaMs)
            var newDuration = UInt64(newEnd) - zoomClip.timelineStartMs
            if canSnap {
                let proposedEnd = zoomClip.timelineStartMs + newDuration
                if let snapped = SnapEngine.snap(proposedMs: proposedEnd, targets: snapTargets, thresholdPx: 8, pixelsPerSecond: pixelsPerSecond, excludeMs: [zoomClip.timelineEndMs]) {
                    if snapped > zoomClip.timelineStartMs + minDurationMs {
                        newDuration = snapped - zoomClip.timelineStartMs
                    }
                }
            }
            onResizeRight(id, newDuration)

        case .easeIn(let id):
            let newEaseIn = max(0, Int64(zoomClip.easeInMs) + deltaMs)
            // Ensure ease-in + ease-out doesn't exceed duration - minBody
            let maxEaseIn = Int64(zoomClip.durationMs) - Int64(zoomClip.easeOutMs) - Int64(minDurationMs)
            let clamped = UInt64(max(0, min(newEaseIn, maxEaseIn)))
            onResizeEaseIn(id, clamped)

        case .easeOut(let id):
            // Dragging left (negative offset) makes ease-out bigger
            let newEaseOut = max(0, Int64(zoomClip.easeOutMs) - deltaMs)
            let maxEaseOut = Int64(zoomClip.durationMs) - Int64(zoomClip.easeInMs) - Int64(minDurationMs)
            let clamped = UInt64(max(0, min(newEaseOut, maxEaseOut)))
            onResizeEaseOut(id, clamped)
        }
    }

    // MARK: - Zoom Preview

    private func startPreviewTimer(for zc: ZoomClip) {
        let alreadyShowing = previewClipId == zc.id
        previewTask?.cancel()
        previewTask = Task {
            // 300ms delay for initial show, 100ms debounce for position updates
            try? await Task.sleep(for: .milliseconds(alreadyShowing ? 100 : 300))
            guard !Task.isCancelled else { return }

            // Use the actual hover position; fall back to clip midpoint
            let posMs = hoverTimelinePositionMs ?? (zc.timelineStartMs + zc.durationMs / 2)
            let posSec = Double(posMs) / 1000.0
            guard let source = clipManager.sourceTimeForTimelinePosition(posSec),
                  let mediaItemId = source.mediaItemId,
                  let mediaItem = clipManager.mediaItems.first(where: { $0.id == mediaItemId })
            else { return }

            let image = await thumbnailCache.zoomPreviewFrame(
                mediaItem: mediaItem,
                sourceTimeMs: source.sourceTimeMs
            )
            guard !Task.isCancelled else { return }
            previewImage = image
            previewZoomClip = zc
            previewVideoWidth = mediaItem.width
            previewVideoHeight = mediaItem.height
            previewClipId = zc.id
        }
    }

    private func cancelPreview() {
        previewTask?.cancel()
        previewTask = nil
        previewClipId = nil
        previewImage = nil
        previewZoomClip = nil
    }
}

/// Renders a single zoom clip as a styled rounded rectangle with optional ease-in/out regions.
struct ZoomClipView: View {
    let zoomClip: ZoomClip
    let width: Double
    let isSelected: Bool
    let isMagneted: Bool
    var isHovered: Bool = false
    var leftEdgeHighlighted: Bool = false
    var rightEdgeHighlighted: Bool = false
    var easeInEdgeHighlighted: Bool = false
    var easeOutEdgeHighlighted: Bool = false
    var easeInResizeOffset: Double = 0
    var easeOutResizeOffset: Double = 0
    var isFlashing: Bool = false
    var isScaleDragging: Bool = false
    var liveScale: Double? = nil

    var body: some View {
        ZStack(alignment: .leading) {
            // Base fill
            RoundedRectangle(cornerRadius: 4)
                .fill(fillColor)

            // Ease-in gradient overlay
            if zoomClip.easeEnabled {
                let easeInWidth = max(0, zoomClip.easeInFraction * width + easeInResizeOffset)
                if easeInWidth > 0 {
                    LinearGradient(
                        colors: [Color.blue.opacity(0.0), fillColor],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .frame(width: easeInWidth, height: 24)
                    .clipShape(UnevenRoundedRectangle(
                        topLeadingRadius: 4, bottomLeadingRadius: 4,
                        bottomTrailingRadius: 0, topTrailingRadius: 0
                    ))

                    // Ease-in boundary line
                    Rectangle()
                        .fill(easeInEdgeHighlighted ? Color.orange : Color.blue.opacity(0.4))
                        .frame(width: easeInEdgeHighlighted ? 2 : 1, height: 20)
                        .offset(x: easeInWidth)
                }

                // Ease-out gradient overlay
                let easeOutWidth = max(0, zoomClip.easeOutFraction * width + easeOutResizeOffset)
                if easeOutWidth > 0 {
                    HStack {
                        Spacer(minLength: 0)
                        LinearGradient(
                            colors: [fillColor, Color.blue.opacity(0.0)],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                        .frame(width: easeOutWidth, height: 24)
                        .clipShape(UnevenRoundedRectangle(
                            topLeadingRadius: 0, bottomLeadingRadius: 0,
                            bottomTrailingRadius: 4, topTrailingRadius: 4
                        ))
                    }

                    // Ease-out boundary line
                    HStack {
                        Spacer(minLength: 0)
                        Rectangle()
                            .fill(easeOutEdgeHighlighted ? Color.orange : Color.blue.opacity(0.4))
                            .frame(width: easeOutEdgeHighlighted ? 2 : 1, height: 20)
                            .padding(.trailing, easeOutWidth)
                    }
                }
            }

            // Border
            RoundedRectangle(cornerRadius: 4)
                .strokeBorder(borderColor, lineWidth: (isMagneted || isHovered) ? 2 : 1)

            // Scale label
            if isScaleDragging, let scale = liveScale {
                HStack(spacing: 2) {
                    Image(systemName: "arrow.up.arrow.down")
                        .font(.system(size: 8, weight: .bold))
                    Text(String(format: "%.2fx", scale))
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(Capsule().fill(Color.black.opacity(0.5)))
                .frame(maxWidth: .infinity)
            } else {
                Text(String(format: "%.1fx", zoomClip.scale))
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(isSelected ? .purple : .blue)
                    .frame(maxWidth: .infinity)
            }

            // Left edge resize indicator
            if leftEdgeHighlighted {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.orange.opacity(0.8))
                    .frame(width: 3, height: 18)
                    .padding(.leading, 1)
            }

            // Right edge resize indicator
            if rightEdgeHighlighted {
                HStack {
                    Spacer()
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.orange.opacity(0.8))
                        .frame(width: 3, height: 18)
                        .padding(.trailing, 1)
                }
            }
        }
        .frame(width: width, height: 24)
        .animation(.easeOut(duration: 0.5), value: isFlashing)
    }

    private var fillColor: Color {
        if isFlashing { return Color.green.opacity(0.35) }
        if isHovered { return Color.orange.opacity(0.2) }
        if isMagneted { return Color.purple.opacity(0.25) }
        if isSelected { return Color.purple.opacity(0.2) }
        return Color.blue.opacity(0.15)
    }

    private var borderColor: Color {
        if isFlashing { return Color.green }
        if isHovered { return Color.orange }
        if isMagneted { return Color.purple }
        if isSelected { return Color.purple }
        return Color.blue.opacity(0.5)
    }
}

/// Small popover showing a zoom-transformed video frame for quick preview.
/// Applies the same scaleEffect + anchor approach as PreviewView.
struct ZoomPreviewPopover: View {
    let image: NSImage?
    let scale: Double
    let centerX: Double
    let centerY: Double
    let videoWidth: Double
    let videoHeight: Double

    private var anchor: UnitPoint {
        guard videoWidth > 0, videoHeight > 0 else { return .center }
        let ax = (centerX / videoWidth).clamped(to: 0...1)
        let ay = (centerY / videoHeight).clamped(to: 0...1)
        return UnitPoint(x: ax, y: ay)
    }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Group {
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .scaleEffect(scale, anchor: anchor)
                } else {
                    ProgressView()
                }
            }
            .frame(width: 200, height: 120)
            .clipped()

            Text(String(format: "%.1fx", scale))
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(.white)
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
                .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 3))
                .padding(4)
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}
