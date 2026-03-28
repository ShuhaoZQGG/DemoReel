# 17. Export Ignores All Editor Edits (Zoom, Clips, Timeline)

**Problem:** The preview in the editor correctly showed all edits — zoom keyframes, clip reordering, gaps — but the exported video was identical to the raw source recording with none of the edits applied.

**Root cause (three disconnects between preview and export):**

1. **No ClipManager data passed to export.** `ExportSheet` only received `zoomConfig`, `styleConfig`, and `cursorConfig` from `EditorView`. The `ClipManager` — which holds all clip ordering, boundaries, and edited zoom clips — was never passed through. The exporter had no knowledge of any edits.

2. **Sequential source reading instead of clip-aware reading.** `NativeExporter` used a single `AVAssetReader` with `while copyNextSampleBuffer()` to read every frame sequentially from the source video. This completely ignored clip boundaries, reordering, and gaps. The preview used `ClipManager.sourceTimeForTimelinePosition()` to map timeline position → source time per clip.

3. **Zoom keyframes regenerated from raw events.** The exporter called `generateZoomKeyframesWithConfig(events:config:)` to auto-generate zoom keyframes from the event log — the same initial keyframes that the user then edited in the timeline. Meanwhile, the preview used `clipManager.zoomKeyframesForPreview()` which returns the user's edited `ZoomClip`s converted to `ZoomKeyframe`s in timeline coordinates.

**Fix (three-part):**

1. **Pass clip data to the export pipeline.** Added `clips: [Clip]` and `zoomKeyframes: [ZoomKeyframe]` parameters to `ExportSheet` and `NativeExporter`. `EditorView` now passes `clipManager.clipsByTimelineOrder` and `clipManager.zoomKeyframesForPreview()` when presenting the export sheet.

2. **Clip-aware frame reading.** Replaced the single sequential `AVAssetReader` loop with a per-clip approach:
```swift
for clip in sortedClips {
    // Fill timeline gaps with black frames
    // ...

    // Read only this clip's source range
    let clipReader = try AVAssetReader(asset: asset)
    clipReader.timeRange = CMTimeRange(
        start: CMTime(value: Int64(clip.sourceStartMs), timescale: 1000),
        end: CMTime(value: Int64(clip.sourceEndMs), timescale: 1000)
    )
    // ... read frames, map to timeline timestamps
}
```
Each clip gets its own `AVAssetReader` with a `timeRange` matching its source boundaries. Frames are read in timeline order, and gaps between clips produce black frames (matching the preview's behavior).

3. **Timeline-coordinate zoom lookup.** The exporter now uses the editor's zoom keyframes directly (already in timeline coordinates) and looks up zoom state using `timelineMs` — the mapped timeline position — instead of source PTS. Cursor lookup still uses source time since cursor data is recorded in source coordinates.

**Secondary bug — AVAssetWriter crash ("The operation could not be completed"):**

The initial fix used `CMTime(value: Int64(timelineMs), timescale: 1000)` for output presentation timestamps. This caused duplicate PTS values when multiple source frames mapped to the same millisecond (common at high frame rates where frame intervals are sub-millisecond).

**Fix:** Use a strictly monotonic frame counter for output PTS:
```swift
var outputFrameIndex = 0
// ...
let outputPTS = CMTime(value: Int64(outputFrameIndex), timescale: CMTimeScale(fps))
outputFrameIndex += 1
```
This guarantees PTS always increases by exactly one frame duration, which AVAssetWriter requires.

**Also added:** Fallback for empty clips array — if no clips exist (edge case), creates a single clip spanning the full source video to prevent zero-frame exports.

**Lesson:** When an app has separate preview and export pipelines, the export must consume the same edited state that the preview uses — not regenerate it from raw inputs. The preview's data flow was: `ClipManager` → timeline position → source time mapping → zoom lookup in timeline coords. The export's data flow was: raw source → sequential frames → zoom lookup from event log. These pipelines must be unified. Additionally, AVAssetWriter strictly requires monotonically increasing presentation timestamps — never derive PTS from timestamp mapping that could produce duplicates; use a frame counter instead.
