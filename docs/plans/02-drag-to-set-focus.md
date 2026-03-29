# Plan: Zoom Focus Point Repositioning

**Priority:** 2 (High)
**Status:** Planned
**Scope:** PreviewView + ZoomClip + ClipManager

## Problem

Zoom clip `centerX`/`centerY` is set at creation time from the cursor position during recording. There's no way to adjust the zoom focus point afterward. If the auto-detected center is wrong, the user must delete and recreate the zoom clip.

## Approach

Add a draggable focus-point overlay on the preview when a zoom clip is selected. Dragging it updates `centerX`/`centerY` on the selected ZoomClip.

### Implementation Steps

1. **Focus point indicator on PreviewView** — When a zoom clip is selected and the playhead is within that clip's range, render a crosshair/circle overlay at the clip's `(centerX, centerY)` position (mapped to preview coordinates using videoWidth/videoHeight).

2. **Drag gesture on the indicator** — Attach a `DragGesture` that updates the zoom clip's center in real-time. Convert drag position from preview coordinates back to video coordinates (divide by render size, multiply by videoWidth/videoHeight).

3. **Pass selected zoom clip binding** — PreviewView needs to know which zoom clip is selected. Pass `selection` and `clipManager` so it can read/write the active zoom clip's center.

4. **Visual feedback** — Show the focus point as a small crosshair with a dashed circle (similar to Screen Studio). Fade it in/out based on selection state. Show connecting lines to the zoom bounding box edges for clarity.

5. **Keyboard nudge** — Arrow keys nudge the focus point by 10px (or 1px with Shift held) when a zoom clip is selected.

### Files to Modify

- `PreviewView.swift` — Add focus point overlay, drag gesture, coordinate mapping
- `EditorView.swift` — Pass selection state to PreviewView
- `KeyboardShortcutMonitor.swift` — Arrow key nudge for focus point

### Risks

- Coordinate mapping between preview display size and video native resolution needs to account for padding, corner radius, and the zoom transform itself. Must use pre-zoom coordinates.
- Drag during playback could be janky — should pause playback while dragging the focus point.
