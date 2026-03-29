import Foundation

/// Computes snap targets and finds the nearest match during drag operations.
/// Stateless — targets are recomputed each drag frame.
struct SnapEngine {

    struct SnapTarget {
        let timelineMs: UInt64
    }

    /// Collect all snap targets from current timeline state.
    static func targets(
        playheadMs: UInt64,
        clips: [Clip],
        zoomClips: [ZoomClip],
        trimStartMs: UInt64,
        trimEndMs: UInt64
    ) -> [SnapTarget] {
        var result: [SnapTarget] = []
        result.append(SnapTarget(timelineMs: playheadMs))
        result.append(SnapTarget(timelineMs: trimStartMs))
        result.append(SnapTarget(timelineMs: trimEndMs))
        for clip in clips {
            result.append(SnapTarget(timelineMs: clip.timelineStartMs))
            result.append(SnapTarget(timelineMs: clip.timelineEndMs))
        }
        for zc in zoomClips {
            result.append(SnapTarget(timelineMs: zc.timelineStartMs))
            result.append(SnapTarget(timelineMs: zc.timelineEndMs))
        }
        return result
    }

    /// Find the nearest snap target within a pixel threshold.
    /// Returns the snapped ms value, or nil if nothing is close enough.
    /// `excludeMs` prevents a clip from snapping to its own edges.
    static func snap(
        proposedMs: UInt64,
        targets: [SnapTarget],
        thresholdPx: Double,
        pixelsPerSecond: Double,
        excludeMs: Set<UInt64> = []
    ) -> UInt64? {
        let thresholdMs = UInt64(thresholdPx / pixelsPerSecond * 1000)
        var bestTarget: UInt64?
        var bestDist: UInt64 = .max

        for t in targets where !excludeMs.contains(t.timelineMs) {
            let dist = proposedMs > t.timelineMs
                ? proposedMs - t.timelineMs
                : t.timelineMs - proposedMs
            if dist <= thresholdMs && dist < bestDist {
                bestDist = dist
                bestTarget = t.timelineMs
            }
        }
        return bestTarget
    }
}
