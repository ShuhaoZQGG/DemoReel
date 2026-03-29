# Plan: Continuous Zoom Scale Control

**Priority:** 6 (Medium)
**Status:** Planned
**Scope:** ZoomClipTrack + TimelineView + ZoomClipView

## Problem

Zoom scale is set via a dropdown with fixed presets (1.5x, 2.0x, 2.5x, 3.0x, 4.0x). Users can't fine-tune to values like 1.8x or 2.3x, and changing scale requires selecting the clip then navigating a menu.

## Approach

Two improvements: (1) vertical drag on zoom clips to adjust scale continuously, (2) replace the dropdown with a slider in the transport bar.

### Implementation Steps

1. **Vertical drag to adjust scale** — In `ZoomClipTrack`, when a drag gesture starts in the middle of a zoom clip (not on edges), track vertical movement. Horizontal = move, but if vertical exceeds a threshold first, switch to scale-adjust mode. Drag up = increase scale, drag down = decrease. Map ~100px of vertical drag to the 1.0x–5.0x range.

2. **Scale slider in transport bar** — Replace the scale `Menu` dropdown with a compact slider (range 1.25...5.0, step 0.25) plus a text field showing the current value. Keep the menu as a secondary option (click the value label to get presets).

3. **Live preview during drag** — As the user drags vertically, update the zoom clip's scale in real-time so the preview reflects the change immediately.

4. **Visual feedback on clip** — The scale label inside `ZoomClipView` already shows the value. During vertical drag, make it larger/bolder and show a small up/down arrow indicator.

### Files to Modify

- `ZoomKeyframeEditor.swift` — Add vertical drag detection and scale adjustment to the gesture handler
- `TimelineView.swift` — Replace scale Menu with Slider + text display
- `ZoomClipView` (in ZoomKeyframeEditor.swift) — Visual feedback during scale drag

### Risks

- Disambiguating horizontal (move) vs vertical (scale) drag requires a gesture lock after the first ~5px of movement. Already have `gestureLocked` state — extend it to track the locked direction.
- Vertical drag on a 24px-tall clip is a tight target. May need to increase track height or add a modifier key (e.g., Option+drag = scale).
