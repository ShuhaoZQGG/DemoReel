import Foundation
import AVFoundation

/// Manages an ordered list of clips and provides time mapping
/// between source video time and the visual/output timeline.
@Observable
final class ClipManager {
    var clips: [Clip] = []

    // MARK: - Undo / Redo

    private struct Snapshot {
        let clips: [Clip]
        let zoomClips: [ZoomClip]
    }

    private static let maxUndoSteps = 50

    private var undoStack: [Snapshot] = []
    private var redoStack: [Snapshot] = []
    /// Timestamp of last undo snapshot — used to debounce slider edits.
    private var lastSnapshotDate: Date = .distantPast

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    /// Save current state before a mutation. Clears the redo stack.
    func saveUndoState() {
        undoStack.append(Snapshot(clips: clips, zoomClips: zoomClips))
        if undoStack.count > Self.maxUndoSteps {
            undoStack.removeFirst(undoStack.count - Self.maxUndoSteps)
        }
        redoStack.removeAll()
        lastSnapshotDate = Date()
    }

    /// Save undo state only if >500 ms since the last save (for continuous slider edits).
    func saveUndoStateDebounced() {
        guard Date().timeIntervalSince(lastSnapshotDate) > 0.5 else { return }
        saveUndoState()
    }

    func undo() {
        guard let snapshot = undoStack.popLast() else { return }
        redoStack.append(Snapshot(clips: clips, zoomClips: zoomClips))
        clips = snapshot.clips
        zoomClips = snapshot.zoomClips
    }

    func redo() {
        guard let snapshot = redoStack.popLast() else { return }
        undoStack.append(Snapshot(clips: clips, zoomClips: zoomClips))
        clips = snapshot.clips
        zoomClips = snapshot.zoomClips
    }

    // MARK: - Media Pool

    var mediaItems: [MediaItem] = []

    /// Import a video file into the media pool. Returns the new MediaItem.
    @discardableResult
    func addMediaItem(url: URL) async throws -> MediaItem {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration)
        let durationMs = UInt64(max(0, CMTimeGetSeconds(duration)) * 1000)

        var width: Double = 1920
        var height: Double = 1080
        if let track = try await asset.loadTracks(withMediaType: .video).first {
            let size = try await track.load(.naturalSize)
            width = Double(size.width)
            height = Double(size.height)
        }

        let name = url.deletingPathExtension().lastPathComponent
        let item = MediaItem(filePath: url.path, durationMs: durationMs, width: width, height: height, name: name)
        await MainActor.run {
            mediaItems.append(item)
        }
        return item
    }

    /// Add a clip from a media pool item at the end of the timeline.
    func addClipFromMedia(_ mediaItem: MediaItem) {
        saveUndoState()
        let startMs = timelineEndMs
        let clip = Clip(
            sourceStartMs: 0,
            sourceEndMs: mediaItem.durationMs,
            timelineStartMs: startMs,
            mediaItemId: mediaItem.id
        )
        clips.append(clip)
    }

    /// Add a clip from a media pool item at a specific timeline position.
    func addClipFromMedia(_ mediaItem: MediaItem, atTimelineMs: UInt64) {
        saveUndoState()
        let clip = Clip(
            sourceStartMs: 0,
            sourceEndMs: mediaItem.durationMs,
            timelineStartMs: atTimelineMs,
            mediaItemId: mediaItem.id
        )
        clips.append(clip)
    }

    /// Look up the media item for a clip (nil for legacy single-source clips).
    func mediaItem(for clip: Clip) -> MediaItem? {
        guard let id = clip.mediaItemId else { return nil }
        return mediaItems.first { $0.id == id }
    }

    /// Get the video file URL for a clip, falling back to a legacy URL if needed.
    func videoURL(for clip: Clip, legacyURL: URL?) -> URL? {
        if let item = mediaItem(for: clip) {
            return item.fileURL
        }
        return legacyURL
    }

    /// The end of the last clip on the timeline (ms).
    var timelineEndMs: UInt64 {
        clips.map(\.timelineEndMs).max() ?? 0
    }

    /// Total timeline duration in seconds (from 0 to end of last clip).
    var timelineDuration: Double {
        Double(timelineEndMs) / 1000.0
    }

    /// Clips sorted by their timeline position.
    var clipsByTimelineOrder: [Clip] {
        clips.sorted(by: { $0.timelineStartMs < $1.timelineStartMs })
    }

    /// Create the initial single clip spanning the given range.
    func initializeFromTrim(startMs: UInt64, endMs: UInt64) {
        guard endMs > startMs else { return }
        saveUndoState()
        clips = [Clip(sourceStartMs: startMs, sourceEndMs: endMs, timelineStartMs: 0)]
    }

    /// Split the clip containing `sourceTimeMs` into two clips at that point.
    /// The split clip's timeline position is used: left keeps it, right starts right after left.
    func split(atSourceTimeMs ms: UInt64) {
        guard let index = clips.firstIndex(where: { $0.sourceStartMs < ms && $0.sourceEndMs > ms }) else { return }
        saveUndoState()
        let clip = clips[index]
        let leftDurationMs = ms - clip.sourceStartMs
        let left = Clip(
            sourceStartMs: clip.sourceStartMs,
            sourceEndMs: ms,
            speed: clip.speed,
            timelineStartMs: clip.timelineStartMs,
            mediaItemId: clip.mediaItemId
        )
        let right = Clip(
            sourceStartMs: ms,
            sourceEndMs: clip.sourceEndMs,
            speed: clip.speed,
            timelineStartMs: clip.timelineStartMs + leftDurationMs,
            mediaItemId: clip.mediaItemId
        )
        clips.replaceSubrange(index...index, with: [left, right])
    }

    /// Merge clip at `clipIndex` with the clip immediately after it (by array index).
    /// The merged clip uses the left clip's timeline position.
    func merge(clipIndex: Int) {
        guard clipIndex >= 0, clipIndex + 1 < clips.count else { return }
        saveUndoState()
        let left = clips[clipIndex]
        let right = clips[clipIndex + 1]
        let merged = Clip(
            sourceStartMs: left.sourceStartMs,
            sourceEndMs: right.sourceEndMs,
            speed: left.speed,
            timelineStartMs: left.timelineStartMs,
            mediaItemId: left.mediaItemId
        )
        clips.replaceSubrange(clipIndex...clipIndex + 1, with: [merged])
    }

    /// Move a clip to a new timeline position (ms). Prevents overlap by snapping.
    func moveOnTimeline(clipId: UUID, toTimelineMs newStart: UInt64) {
        guard let index = clips.firstIndex(where: { $0.id == clipId }) else { return }
        saveUndoState()
        let clip = clips[index]
        let duration = clip.timelineEndMs - clip.timelineStartMs

        var proposed = newStart
        let proposedEnd = proposed + duration

        // Prevent overlap with other clips
        for other in clips where other.id != clipId {
            if proposed < other.timelineEndMs && proposedEnd > other.timelineStartMs {
                // Overlap detected — snap to nearest non-overlapping position
                let snapBefore = other.timelineStartMs >= duration ? other.timelineStartMs - duration : 0
                let snapAfter = other.timelineEndMs

                let distBefore = proposed > snapBefore ? proposed - snapBefore : snapBefore - proposed
                let distAfter = proposed > snapAfter ? proposed - snapAfter : snapAfter - proposed

                proposed = distBefore <= distAfter ? snapBefore : snapAfter
            }
        }

        clips[index].timelineStartMs = proposed
    }

    /// Delete video clips by their IDs.
    func deleteClips(ids: Set<UUID>) {
        saveUndoState()
        clips.removeAll { ids.contains($0.id) }
    }

    /// Delete zoom clips by their IDs.
    func deleteZoomClips(ids: Set<UUID>) {
        saveUndoState()
        zoomClips.removeAll { ids.contains($0.id) }
    }

    /// Duplicate zoom clips, placing copies immediately after each original.
    /// Returns the IDs of the new clips.
    @discardableResult
    func duplicateZoomClips(ids: Set<UUID>) -> [UUID] {
        saveUndoState()
        let toDuplicate = zoomClips.filter { ids.contains($0.id) }
            .sorted { $0.timelineStartMs < $1.timelineStartMs }
        var newIds: [UUID] = []
        for zc in toDuplicate {
            let newClip = ZoomClip(
                timelineStartMs: zc.timelineEndMs,
                durationMs: zc.durationMs,
                centerX: zc.centerX,
                centerY: zc.centerY,
                scale: zc.scale,
                easeInMs: zc.easeInMs,
                easeOutMs: zc.easeOutMs,
                easeEnabled: zc.easeEnabled
            )
            newIds.append(newClip.id)
            zoomClips.append(newClip)
        }
        return newIds
    }

    /// Find the clip at a given source time.
    func clip(atSourceTimeMs ms: UInt64) -> Clip? {
        clips.first(where: { $0.sourceStartMs <= ms && $0.sourceEndMs > ms })
    }

    /// Find the source time for a given timeline position (seconds).
    /// Returns nil if the position is in a gap (no clip).
    func sourceTimeForTimelinePosition(_ seconds: Double) -> (sourceTimeMs: UInt64, clipIndex: Int, mediaItemId: UUID?)? {
        let posMs = UInt64(seconds * 1000)
        for (i, clip) in clipsByTimelineOrder.enumerated() {
            if posMs >= clip.timelineStartMs && posMs < clip.timelineEndMs {
                let offsetMs = posMs - clip.timelineStartMs
                return (clip.sourceStartMs + offsetMs, i, clip.mediaItemId)
            }
        }
        return nil
    }

    /// Find the next clip's timeline start after a given timeline position (ms).
    func nextClipStart(afterTimelineMs ms: UInt64) -> UInt64? {
        clipsByTimelineOrder
            .first(where: { $0.timelineStartMs > ms })?
            .timelineStartMs
    }

    // MARK: - Zoom Clips

    var zoomClips: [ZoomClip] = []

    /// Add a new zoom clip at the given timeline position. Overlapping clips are allowed.
    func addZoomClip(atTimelineMs ms: UInt64, durationMs: UInt64 = 1000, centerX: Double = 0.5, centerY: Double = 0.5, scale: Double = 2.0) {
        saveUndoState()
        zoomClips.append(ZoomClip(
            timelineStartMs: ms, durationMs: durationMs,
            centerX: centerX, centerY: centerY, scale: scale
        ))
    }

    /// Convert auto-generated keyframes to editable ZoomClips (only if empty).
    func initializeZoomClips(from keyframes: [ZoomKeyframe]) {
        guard zoomClips.isEmpty else { return }
        zoomClips = keyframes.map { kf in
            ZoomClip(timelineStartMs: kf.startMs, durationMs: kf.endMs - kf.startMs,
                     centerX: kf.centerX, centerY: kf.centerY, scale: kf.scale)
        }
    }

    /// Additive regeneration: only add non-overlapping new zoom clips.
    func regenerateZoomClips(from keyframes: [ZoomKeyframe]) {
        for kf in keyframes {
            let newStart = kf.startMs
            let newEnd = kf.endMs
            let overlaps = zoomClips.contains { zc in
                newStart < zc.timelineEndMs && newEnd > zc.timelineStartMs
            }
            if !overlaps {
                zoomClips.append(ZoomClip(
                    timelineStartMs: newStart, durationMs: newEnd - newStart,
                    centerX: kf.centerX, centerY: kf.centerY, scale: kf.scale
                ))
            }
        }
    }

    /// Split a zoom clip at the given timeline position.
    func splitZoomClip(atTimelineMs ms: UInt64) {
        guard let index = zoomClips.firstIndex(where: { ms > $0.timelineStartMs && ms < $0.timelineEndMs }) else { return }
        saveUndoState()
        let zc = zoomClips[index]
        let leftDuration = ms - zc.timelineStartMs
        let rightDuration = zc.durationMs - leftDuration

        let left = ZoomClip(
            timelineStartMs: zc.timelineStartMs, durationMs: leftDuration,
            centerX: zc.centerX, centerY: zc.centerY, scale: zc.scale
        )
        let right = ZoomClip(
            timelineStartMs: ms, durationMs: rightDuration,
            centerX: zc.centerX, centerY: zc.centerY, scale: zc.scale
        )
        zoomClips.replaceSubrange(index...index, with: [left, right])
    }

    /// Merge two adjacent zoom clips.
    func mergeZoomClips(leftIndex: Int) {
        guard leftIndex >= 0, leftIndex + 1 < zoomClips.count else { return }
        saveUndoState()
        let left = zoomClips[leftIndex]
        let right = zoomClips[leftIndex + 1]
        let merged = ZoomClip(
            timelineStartMs: left.timelineStartMs,
            durationMs: (right.timelineEndMs - left.timelineStartMs),
            centerX: left.centerX, centerY: left.centerY, scale: left.scale
        )
        zoomClips.replaceSubrange(leftIndex...leftIndex + 1, with: [merged])
    }

    /// Move a zoom clip to a new timeline position. Prevents overlap.
    func moveZoomClipOnTimeline(clipId: UUID, toTimelineMs newStart: UInt64) {
        guard let index = zoomClips.firstIndex(where: { $0.id == clipId }) else { return }
        saveUndoState()
        let zc = zoomClips[index]

        var proposed = newStart
        let proposedEnd = proposed + zc.durationMs

        for other in zoomClips where other.id != clipId {
            if proposed < other.timelineEndMs && proposedEnd > other.timelineStartMs {
                let snapBefore = other.timelineStartMs >= zc.durationMs ? other.timelineStartMs - zc.durationMs : 0
                let snapAfter = other.timelineEndMs
                let distBefore = proposed > snapBefore ? proposed - snapBefore : snapBefore - proposed
                let distAfter = proposed > snapAfter ? proposed - snapAfter : snapAfter - proposed
                proposed = distBefore <= distAfter ? snapBefore : snapAfter
            }
        }

        zoomClips[index].timelineStartMs = proposed
    }

    /// Convert zoom clips to ZoomKeyframes for preview rendering.
    func zoomKeyframesForPreview() -> [ZoomKeyframe] {
        zoomClips.map { zc in
            ZoomKeyframe(
                startMs: zc.timelineStartMs, endMs: zc.timelineEndMs,
                centerX: zc.centerX, centerY: zc.centerY, scale: zc.scale
            )
        }
    }

    /// Compute zoom scale at a given timeline timestamp, using per-clip ease values when enabled.
    static func zoomScaleWithPerClipEase(
        zoomClips: [ZoomClip],
        timestampMs: UInt64,
        globalConfig: ZoomConfig
    ) -> Double {
        for zc in zoomClips {
            guard timestampMs >= zc.timelineStartMs && timestampMs <= zc.timelineEndMs else { continue }

            let kf = [ZoomKeyframe(
                startMs: zc.timelineStartMs, endMs: zc.timelineEndMs,
                centerX: zc.centerX, centerY: zc.centerY, scale: zc.scale
            )]

            // Always derive hold from clip duration — global holdMs is only for auto-generation
            let easeIn = zc.easeEnabled ? zc.easeInMs : globalConfig.easeInMs
            let easeOut = zc.easeEnabled ? zc.easeOutMs : globalConfig.easeOutMs
            let holdMs = zc.durationMs > (easeIn + easeOut)
                ? zc.durationMs - easeIn - easeOut
                : 0
            let clipConfig = globalConfig.with(
                scale: zc.scale,
                easeInMs: easeIn,
                holdMs: holdMs,
                easeOutMs: easeOut,
                enabled: true
            )
            return zoomScaleAt(keyframes: kf, timestampMs: timestampMs, config: clipConfig)
        }
        return 1.0
    }

    /// Map source time to timeline position (seconds), or nil if not on timeline.
    func timelinePosition(forSourceTimeMs ms: UInt64) -> Double? {
        for clip in clips {
            if ms >= clip.sourceStartMs && ms < clip.sourceEndMs {
                let offsetMs = ms - clip.sourceStartMs
                return Double(clip.timelineStartMs + offsetMs) / 1000.0
            }
        }
        // Exactly at the end of a clip
        for clip in clips {
            if ms == clip.sourceEndMs {
                return Double(clip.timelineEndMs) / 1000.0
            }
        }
        return nil
    }
}
