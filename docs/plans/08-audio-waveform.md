# Plan: Audio Waveform Visualization

**Priority:** 8 (Low)
**Status:** Planned
**Scope:** TimelineView + new WaveformCache

## Problem

Without audio waveforms, users can't visually locate speech, clicks, or silence on the timeline. They must scrub and listen (once audio playback is added) to find the right moments for zoom placement.

## Approach

Extract audio samples from source videos using AVFoundation, downsample to a displayable resolution, and render as a waveform behind clip segments on the timeline.

### Implementation Steps

1. **WaveformCache class** — Extract audio samples using `AVAssetReader` with `AVAssetReaderTrackOutput` for the audio track. Downsample to ~200 samples per second of video (enough for visual display). Cache per mediaItemId.

2. **Async extraction** — Run extraction in a background Task on clip load. Store as `[Float]` arrays (normalized -1...1 amplitude).

3. **Render in ClipSegmentView** — Draw the waveform as a `Canvas` behind the clip content. Map source time range to sample indices. Use a semi-transparent fill so it doesn't overpower the clip visuals.

4. **Responsive to zoom** — At low timeline zoom, aggregate samples (max amplitude per pixel). At high zoom, show individual samples. Recompute visible range on scroll.

5. **Handle clips without audio** — Some screen recordings may have no audio track. Show nothing (no error).

### Files to Modify

- New: `Editor/WaveformCache.swift`
- `TimelineView.swift` — Pass waveform data to ClipSegmentView
- `ClipSegmentView` (in TimelineView.swift) — Render waveform canvas layer
- `EditorView.swift` — Initialize WaveformCache, trigger extraction on media import

### Risks

- Audio extraction can be slow for long recordings. Must be fully async and cancellable.
- Memory: 200 samples/sec × 60 seconds × 4 bytes = ~48KB per minute. Negligible.
- Videos without audio tracks — handle gracefully with `AVAssetTrack` availability check.
