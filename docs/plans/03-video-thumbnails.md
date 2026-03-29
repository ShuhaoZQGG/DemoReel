# Plan: Video Thumbnail Strip on Timeline Clips

**Priority:** 3 (High)
**Status:** Planned
**Scope:** TimelineView + ClipSegmentView + new ThumbnailCache

## Problem

Clip segments on the timeline are plain colored rectangles. Users must scrub to find specific moments. Real NLEs show frame thumbnails inside clip segments, making the timeline visually navigable.

## Approach

Use `AVAssetImageGenerator` to sample frames at regular intervals. Cache thumbnails keyed by (mediaItemId, sourceTimeMs). Render them as a horizontal strip inside each `ClipSegmentView`.

### Implementation Steps

1. **ThumbnailCache class** — `@Observable` singleton that generates and caches `NSImage` thumbnails. Key: `(mediaItemId: UUID, sourceTimeMs: UInt64)`. Uses `AVAssetImageGenerator` with `maximumSize` of ~80x45 (small, for timeline display).

2. **Async generation** — On clip appearance or timeline zoom change, request thumbnails at intervals based on `pixelsPerSecond` (e.g., one thumbnail per 60px of clip width). Use `Task` to generate in background; update cache on MainActor.

3. **Render in ClipSegmentView** — Replace the plain fill with an `HStack(spacing: 0)` of thumbnail images, clipped to the clip's rounded rectangle. Fall back to colored fill while thumbnails load.

4. **Invalidation** — Regenerate when timeline zoom level changes significantly (different number of thumbnails needed). Don't regenerate on every scroll.

5. **Memory management** — Limit cache to ~500 thumbnails. Evict least-recently-used entries. Each thumbnail at 80x45 is ~15KB, so 500 ≈ 7.5MB.

### Files to Modify

- New: `Editor/ThumbnailCache.swift`
- `TimelineView.swift` — Pass thumbnail cache to ClipSegmentView
- `ClipSegmentView` (in TimelineView.swift) — Render thumbnail strip instead of plain fill
- `EditorView.swift` — Initialize and own the ThumbnailCache

### Risks

- `AVAssetImageGenerator` can be slow for large videos. Must be fully async and cancellable.
- Too many thumbnails at high zoom levels could cause frame drops. Throttle generation and use a fixed max density.
- Multiple media items means multiple AVAssets open for thumbnail generation. Pool or limit concurrent generators.
