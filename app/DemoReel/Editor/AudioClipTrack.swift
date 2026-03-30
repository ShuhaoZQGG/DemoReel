import SwiftUI

/// Renders and edits audio clips on a timeline audio track.
/// Supports drag-to-move, edge-resize (trim), selection, and waveform display.
struct AudioClipTrack: View {
    let clips: [AudioClip]
    let pixelsPerSecond: Double
    let trackHeight: Double
    let trackLabel: String
    let trackColor: Color
    let selectedIds: Set<UUID>
    var scissorModeActive: Bool = false
    var hoveredClipId: UUID? = nil
    var hoverTimelinePositionMs: UInt64? = nil
    var waveformSamples: (AudioClip) -> [Float]
    var onSelect: (UUID, Bool) -> Void
    var onDragMove: (UUID, UInt64) -> Void
    var onResizeLeft: (UUID, UInt64) -> Void
    var onResizeRight: (UUID, UInt64) -> Void
    var onScissorCut: ((UInt64) -> Void)? = nil
    var snapTargets: [SnapEngine.SnapTarget] = []
    var snappingEnabled: Bool = false
    @Binding var activeSnapLineMs: UInt64?

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
            ForEach(clips) { clip in
                let x = Double(clip.timelineStartMs) / 1000.0 * pixelsPerSecond
                let width = clip.sourceDuration * pixelsPerSecond
                let isDragging = clip.id == draggingId
                let isSelected = selectedIds.contains(clip.id)

                let (visualX, visualWidth) = resizeVisuals(for: clip, baseX: x, baseWidth: width)

                AudioClipView(
                    clip: clip,
                    width: max(visualWidth, 8),
                    height: trackHeight,
                    isSelected: isSelected,
                    isHovered: scissorModeActive && hoveredClipId == clip.id,
                    trackLabel: trackLabel,
                    trackColor: trackColor,
                    leftEdgeHighlighted: hoveredEdge == .leftEdge(clip.id),
                    rightEdgeHighlighted: hoveredEdge == .rightEdge(clip.id),
                    waveformSamples: waveformSamples(clip)
                )
                .onContinuousHover { phase in
                    guard !gestureLocked else { return }
                    switch phase {
                    case .active(let location):
                        let clipWidth = max(visualWidth, 8)
                        if location.x < edgeHitZone {
                            hoveredEdge = .leftEdge(clip.id)
                            NSCursor.resizeLeftRight.set()
                        } else if location.x > clipWidth - edgeHitZone {
                            hoveredEdge = .rightEdge(clip.id)
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
                        onSelect(clip.id, isCmd)
                    }
                }
                .highPriorityGesture(
                    DragGesture(minimumDistance: 3)
                        .onChanged { value in
                            if !gestureLocked {
                                let localX = value.startLocation.x
                                let clipWidth = max(visualWidth, 8)
                                if localX < edgeHitZone {
                                    resizingEdge = .left(clip.id)
                                } else if localX > clipWidth - edgeHitZone {
                                    resizingEdge = .right(clip.id)
                                } else {
                                    draggingId = clip.id
                                }
                                gestureLocked = true
                            }

                            let canSnap = snappingEnabled && !NSEvent.modifierFlags.contains(.option)

                            if resizingEdge != nil {
                                resizeOffset = value.translation.width
                            } else if draggingId != nil {
                                let currentX = Double(clip.timelineStartMs) / 1000.0 * pixelsPerSecond
                                let proposedX = max(0, currentX + value.translation.width)
                                let proposedMs = UInt64(proposedX / pixelsPerSecond * 1000)

                                if canSnap {
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
                        }
                        .onEnded { _ in
                            if let edge = resizingEdge {
                                applyResize(edge: edge, clip: clip, offset: resizeOffset)
                            } else if draggingId != nil {
                                let currentX = Double(clip.timelineStartMs) / 1000.0 * pixelsPerSecond
                                let newX = max(0, currentX + dragOffset)
                                let newMs = UInt64(newX / pixelsPerSecond * 1000)
                                onDragMove(clip.id, newMs)
                            }
                            draggingId = nil
                            dragOffset = 0
                            resizingEdge = nil
                            resizeOffset = 0
                            gestureLocked = false
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

    private func resizeVisuals(for clip: AudioClip, baseX: Double, baseWidth: Double) -> (Double, Double) {
        guard let edge = resizingEdge else { return (baseX, baseWidth) }
        switch edge {
        case .left(let id) where id == clip.id:
            let newX = baseX + resizeOffset
            let newWidth = baseWidth - resizeOffset
            return (newX, max(newWidth, 8))
        case .right(let id) where id == clip.id:
            let newWidth = baseWidth + resizeOffset
            return (baseX, max(newWidth, 8))
        default:
            return (baseX, baseWidth)
        }
    }

    private func applyResize(edge: ResizeEdge, clip: AudioClip, offset: Double) {
        let deltaMs = Int64(offset / pixelsPerSecond * 1000)
        let minDurationMs: UInt64 = 100

        switch edge {
        case .left(let id):
            let newStart = max(0, Int64(clip.timelineStartMs) + deltaMs)
            let maxStart = Int64(clip.timelineEndMs) - Int64(minDurationMs)
            let clampedStart = UInt64(min(newStart, maxStart))
            onResizeLeft(id, clampedStart)

        case .right(let id):
            let newEnd = max(Int64(clip.timelineStartMs) + Int64(minDurationMs),
                           Int64(clip.timelineEndMs) + deltaMs)
            let newDuration = UInt64(newEnd) - clip.timelineStartMs
            onResizeRight(id, newDuration)
        }
    }
}

/// Renders a single audio clip as a rounded rectangle with waveform and label.
struct AudioClipView: View {
    let clip: AudioClip
    let width: Double
    let height: Double
    let isSelected: Bool
    var isHovered: Bool = false
    let trackLabel: String
    let trackColor: Color
    var leftEdgeHighlighted: Bool = false
    var rightEdgeHighlighted: Bool = false
    var waveformSamples: [Float] = []

    var body: some View {
        ZStack(alignment: .leading) {
            // Base fill
            RoundedRectangle(cornerRadius: 4)
                .fill(fillColor)

            // Waveform
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
                    context.fill(path, with: .color(trackColor.opacity(0.5)))
                }
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .allowsHitTesting(false)
            }

            // Border
            RoundedRectangle(cornerRadius: 4)
                .strokeBorder(borderColor, lineWidth: isHovered ? 2 : 1)

            // Label
            HStack(spacing: 2) {
                if clip.isMuted {
                    Image(systemName: "speaker.slash.fill")
                        .font(.system(size: 7))
                }
                Text(trackLabel)
                    .font(.system(size: 8))
                if clip.volume < 1.0 && !clip.isMuted {
                    Text(String(format: "%.0f%%", clip.volume * 100))
                        .font(.system(size: 7, design: .monospaced))
                }
            }
            .foregroundStyle(isSelected ? trackColor : .secondary)
            .opacity(clip.isMuted ? 0.5 : 1.0)
            .padding(.horizontal, 4)

            // Left edge indicator
            if leftEdgeHighlighted {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.orange.opacity(0.8))
                    .frame(width: 3, height: height - 6)
                    .padding(.leading, 1)
            }

            // Right edge indicator
            if rightEdgeHighlighted {
                HStack {
                    Spacer()
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.orange.opacity(0.8))
                        .frame(width: 3, height: height - 6)
                        .padding(.trailing, 1)
                }
            }
        }
        .frame(width: width, height: height)
        .opacity(clip.isMuted ? 0.5 : 1.0)
    }

    private var fillColor: Color {
        if isHovered { return Color.orange.opacity(0.2) }
        if isSelected { return trackColor.opacity(0.25) }
        return trackColor.opacity(0.12)
    }

    private var borderColor: Color {
        if isHovered { return Color.orange }
        if isSelected { return trackColor }
        return trackColor.opacity(0.4)
    }
}
