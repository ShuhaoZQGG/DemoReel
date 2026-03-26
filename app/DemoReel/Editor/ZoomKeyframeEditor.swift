import SwiftUI

/// Allows drag/resize of individual zoom keyframe regions on the timeline.
struct ZoomKeyframeEditor: View {
    @Binding var keyframes: [ZoomKeyframe]
    let pixelsPerSecond: Double
    let trackHeight: Double

    @State private var draggedIndex: Int?
    @State private var dragOffset: Double = 0

    var body: some View {
        ZStack(alignment: .leading) { 
            ForEach(Array(keyframes.enumerated()), id: \.offset) { index, kf in
                let x = Double(kf.startMs) / 1000.0 * pixelsPerSecond
                let width = Double(kf.endMs - kf.startMs) / 1000.0 * pixelsPerSecond

                ZStack { 
                    RoundedRectangle(cornerRadius: 4)
                        .fill(.blue.opacity(0.25))
                    RoundedRectangle(cornerRadius: 4)
                        .strokeBorder(.blue.opacity(0.6), lineWidth: 1.5)

                    Text(String(format: "%.1fx", kf.scale))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.blue)
                }
                .frame(width: max(width, 8), height: trackHeight)
                .offset(x: x + (draggedIndex == index ? dragOffset : 0))
                .gesture(
                    DragGesture()
                        .onChanged { value in
                            draggedIndex = index
                            dragOffset = value.translation.width
                        }
                        .onEnded { value in
                            applyDrag(index: index, offset: value.translation.width)
                            draggedIndex = nil
                            dragOffset = 0
                        }
                )
            }
        }
    }

    private func applyDrag(index: Int, offset: Double) {
        let deltaMs = Int64(offset / pixelsPerSecond * 1000)
        var kf = keyframes[index]

        let newStart = Int64(kf.startMs) + deltaMs
        let newEnd = Int64(kf.endMs) + deltaMs

        guard newStart >= 0 else { return }

        kf = ZoomKeyframe(
            startMs: UInt64(max(newStart, 0)),
            endMs: UInt64(max(newEnd, 0)),
            centerX: kf.centerX,
            centerY: kf.centerY,
            scale: kf.scale
        )
        keyframes[index] = kf
    }
}
