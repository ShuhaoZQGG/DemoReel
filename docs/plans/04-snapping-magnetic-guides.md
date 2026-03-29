# Plan: Snapping & Magnetic Guides

**Priority:** 4 (Medium)
**Status:** Planned
**Scope:** TimelineView + ZoomClipTrack + ClipManager

## Problem

Clips snap to prevent overlap, but there's no snap-to-playhead, snap-to-clip-edges, or cross-track alignment. Precise editing requires manual positioning, which is slow and error-prone.

## Approach

Add a snap system that detects proximity to key positions during drag operations and magnetically pulls to them. Show visual guide lines when snapping is active.

### Implementation Steps

1. **Snap targets collection** — During any drag, compute a list of snap targets (in timeline ms):
   - Playhead position
   - Start/end of every video clip
   - Start/end of every zoom clip
   - Start/end of trim range
   - Round time values (every 0.5s or 1s, depending on zoom level)

2. **Snap threshold** — Convert a pixel threshold (e.g., 8px) to milliseconds based on current `pixelsPerSecond`. If the dragged edge is within threshold of any target, snap to it.

3. **Apply snapping in drag handlers** — Modify `onDragMove`, `onResizeLeft`, `onResizeRight` in both video clip track and `ZoomClipTrack` to check snap targets before committing the position.

4. **Visual snap guides** — When snapping is active, draw a vertical dashed line at the snap position spanning the full timeline height. Use a distinct color (yellow or cyan). Show for the duration of the snap.

5. **Toggle** — Add a snap toggle button in the transport bar (magnet icon). Default on. Holding Option during drag temporarily disables snapping.

### Files to Modify

- `TimelineView.swift` — Snap target collection, visual guides, toggle button, video clip drag snapping
- `ZoomKeyframeEditor.swift` — Snap support in zoom clip drag/resize handlers
- `KeyboardShortcutMonitor.swift` — Option key modifier detection for snap bypass

### Risks

- O(n) snap target check on every drag frame. Fine for <100 clips, which is the expected range.
- Cross-track snapping (zoom clip edge to video clip edge) requires both tracks to share the same snap target list.
