# Plan: Zoom Preview on Hover

**Priority:** 9 (Low)
**Status:** Planned
**Scope:** TimelineView + PreviewView

## Problem

Users can't see what a zoom clip will look like without moving the playhead into it. When managing multiple zoom clips, it's slow to scrub to each one to check the framing.

## Approach

Show a small tooltip/popover preview when hovering over a zoom clip on the timeline. The popover shows a static frame from the zoom clip's midpoint, with the zoom transform applied.

### Implementation Steps

1. **Hover detection** — Already have `hoveredZoomClipId` in TimelineView. When it changes (and user is not in scissor/placement mode), trigger a preview popover after a short delay (~300ms).

2. **Thumbnail generation** — Use `AVAssetImageGenerator` to grab a single frame at the zoom clip's midpoint source time. Apply the zoom transform (scale + center offset) to the image using Core Graphics.

3. **Popover view** — Show a small (200x120) popover anchored to the hovered zoom clip. Display the zoomed thumbnail with the zoom clip's scale/center applied. Show scale label overlay.

4. **Caching** — Cache the transformed thumbnail per (zoomClipId, centerX, centerY, scale) tuple. Invalidate when any of these change.

5. **Dismissal** — Dismiss on hover exit or when the user starts any drag/interaction.

### Files to Modify

- `TimelineView.swift` — Trigger popover on zoom clip hover
- New: `Editor/ZoomPreviewPopover.swift` — Popover view with thumbnail + zoom transform
- `ThumbnailCache.swift` (from plan 03) — Extend to support zoom-transformed thumbnails

### Risks

- Popover during hover can feel janky if it appears/disappears too quickly. The 300ms delay helps but may need tuning.
- Generating a zoom-transformed thumbnail on every hover is expensive. Caching is essential.
- Depends on plan 03 (thumbnail infrastructure) being implemented first, or needs its own lightweight image generator.
