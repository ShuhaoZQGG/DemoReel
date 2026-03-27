import SwiftUI

/// Renders and edits zoom clips on the timeline's zoom track.
/// Supports drag to move, edge-resize, selection, and displays scale label.
struct ZoomClipTrack: View {
    let clipManager: ClipManager
    let pixelsPerSecond: Double
    let trackHeight: Double
    let isTrackSelected: Bool
    let selectedZoomClipIds: Set<UUID>
    let magnetedZoomClipIds: Set<UUID>
    var hoveredZoomClipId: UUID? = nil
    var scissorModeActive: Bool = false
    var onSelect: (UUID, Bool) -> Void  // (clipId, isCommandClick)
    var onDragMove: (UUID, UInt64) -> Void  // (clipId, newTimelineMs)
    var onResizeLeft: (UUID, UInt64) -> Void  // (clipId, newStartMs)
    var onResizeRight: (UUID, UInt64) -> Void  // (clipId, newEndMs -> durationMs)
    var hoverTimelinePositionMs: UInt64? = nil  // current hover position for scissor cut
    var onScissorCut: ((UInt64) -> Void)? = nil  // (timelineMs) — cut zoom clip at this position

    @State private var draggingId: UUID?
    @State private var dragOffset: Double = 0
    @State private var resizingEdge: ResizeEdge?
    @State private var resizeOffset: Double = 0
    @State private var gestureLocked: Bool = false
    @State private var hoveredEdge: HoveredEdge = .none

    enum ResizeEdge {
        case left(UUID)
        case right(UUID)
    }

    enum HoveredEdge: Equatable {
        case none
        case leftEdge(UUID)
        case rightEdge(UUID)
    }

    private let edgeHitZone: Double = 10

    var body: some View {
        ZStack(alignment: .leading) {
            ForEach(clipManager.zoomClips) { zc in
                let x = Double(zc.timelineStartMs) / 1000.0 * pixelsPerSecond
                let width = zc.timelineDuration * pixelsPerSecond
                let isDragging = zc.id == draggingId
                let isSelected = selectedZoomClipIds.contains(zc.id)
                let isMagneted = magnetedZoomClipIds.contains(zc.id)

                // Compute visual adjustments for resize
                let (visualX, visualWidth) = resizeVisuals(for: zc, baseX: x, baseWidth: width)

                ZoomClipView(
                    zoomClip: zc,
                    width: max(visualWidth, 8),
                    isSelected: isSelected,
                    isMagneted: isMagneted,
                    isHovered: scissorModeActive && hoveredZoomClipId == zc.id,
                    leftEdgeHighlighted: hoveredEdge == .leftEdge(zc.id),
                    rightEdgeHighlighted: hoveredEdge == .rightEdge(zc.id)
                )
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let location):
                        let clipWidth = max(visualWidth, 8)
                        if location.x < edgeHitZone {
                            hoveredEdge = .leftEdge(zc.id)
                            NSCursor.resizeLeftRight.set()
                        } else if location.x > clipWidth - edgeHitZone {
                            hoveredEdge = .rightEdge(zc.id)
                            NSCursor.resizeLeftRight.set()
                        } else {
                            hoveredEdge = .none
                            NSCursor.arrow.set()
                        }
                    case .ended:
                        if hoveredEdge != .none {
                            hoveredEdge = .none
                            NSCursor.arrow.set()
                        }
                    @unknown default:
                        break
                    }
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
                            if !gestureLocked {
                                // Lock gesture type based on where drag started
                                let localX = value.startLocation.x
                                let clipWidth = max(visualWidth, 8)

                                if localX < edgeHitZone {
                                    resizingEdge = .left(zc.id)
                                } else if localX > clipWidth - edgeHitZone {
                                    resizingEdge = .right(zc.id)
                                } else {
                                    draggingId = zc.id
                                }
                                gestureLocked = true
                            }

                            // Update offset based on locked gesture type
                            if resizingEdge != nil {
                                resizeOffset = value.translation.width
                            } else if draggingId != nil {
                                dragOffset = value.translation.width
                            }
                        }
                        .onEnded { value in
                            if let edge = resizingEdge {
                                applyResize(edge: edge, zoomClip: zc, offset: value.translation.width)
                            } else if draggingId != nil {
                                let currentX = Double(zc.timelineStartMs) / 1000.0 * pixelsPerSecond
                                let newX = max(0, currentX + value.translation.width)
                                let newMs = UInt64(newX / pixelsPerSecond * 1000)
                                onDragMove(zc.id, newMs)
                            }
                            draggingId = nil
                            dragOffset = 0
                            resizingEdge = nil
                            resizeOffset = 0
                            gestureLocked = false
                        }
                )
                .offset(x: visualX + (isDragging ? dragOffset : 0))
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

    private func applyResize(edge: ResizeEdge, zoomClip: ZoomClip, offset: Double) {
        let deltaMs = Int64(offset / pixelsPerSecond * 1000)
        let minDurationMs: UInt64 = 100

        switch edge {
        case .left(let id):
            let newStart = max(0, Int64(zoomClip.timelineStartMs) + deltaMs)
            let maxStart = Int64(zoomClip.timelineEndMs) - Int64(minDurationMs)
            let clampedStart = UInt64(min(newStart, maxStart))
            onResizeLeft(id, clampedStart)

        case .right(let id):
            let newEnd = max(Int64(zoomClip.timelineStartMs) + Int64(minDurationMs),
                           Int64(zoomClip.timelineEndMs) + deltaMs)
            let newDuration = UInt64(newEnd) - zoomClip.timelineStartMs
            onResizeRight(id, newDuration)
        }
    }
}

/// Renders a single zoom clip as a styled rounded rectangle.
struct ZoomClipView: View {
    let zoomClip: ZoomClip
    let width: Double
    let isSelected: Bool
    let isMagneted: Bool
    var isHovered: Bool = false
    var leftEdgeHighlighted: Bool = false
    var rightEdgeHighlighted: Bool = false

    var body: some View {
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 4)
                .fill(fillColor)
            RoundedRectangle(cornerRadius: 4)
                .strokeBorder(borderColor, lineWidth: (isMagneted || isHovered) ? 2 : 1)
            Text(String(format: "%.1fx", zoomClip.scale))
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(isSelected ? .purple : .blue)
                .frame(maxWidth: .infinity)

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
    }

    private var fillColor: Color {
        if isHovered { return Color.orange.opacity(0.2) }
        if isMagneted { return Color.purple.opacity(0.25) }
        if isSelected { return Color.purple.opacity(0.2) }
        return Color.blue.opacity(0.15)
    }

    private var borderColor: Color {
        if isHovered { return Color.orange }
        if isMagneted { return Color.purple }
        if isSelected { return Color.purple }
        return Color.blue.opacity(0.5)
    }
}
