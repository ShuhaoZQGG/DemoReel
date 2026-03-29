# Plan: Copy/Paste Zoom Clips

**Priority:** 10 (Low)
**Status:** Planned
**Scope:** ClipManager + KeyboardShortcutMonitor + EditorView

## Problem

Users often want the same zoom pattern repeated (e.g., same scale and center for similar UI interactions). Currently they must manually create and configure each zoom clip individually.

## Approach

Standard Cmd+C / Cmd+V for zoom clips. Copy stores the selected zoom clip(s) as templates. Paste places copies at the playhead position.

### Implementation Steps

1. **Clipboard state on ClipManager** — Add `copiedZoomClips: [ZoomClip]?` property. Stores copies (not references) of the selected zoom clips with their relative timing preserved.

2. **Copy (Cmd+C)** — When zoom clips are selected, deep-copy them into `copiedZoomClips`. Store with times relative to the first clip's start (so the first clip starts at 0, subsequent clips preserve their offsets).

3. **Paste (Cmd+V)** — Create new zoom clips from the copied templates, offset to start at the current playhead position. Assign new UUIDs. Check for overlaps with existing zoom clips — if overlapping, shift to the nearest non-overlapping position.

4. **Duplicate (Cmd+D)** — Shortcut: copy + paste immediately after the selected clip(s). Place the duplicate right after the last selected clip ends.

5. **Visual feedback** — Brief flash/highlight on newly pasted clips so the user can see where they landed.

### Files to Modify

- `ClipManager.swift` — Add `copiedZoomClips`, `copyZoomClips(ids:)`, `pasteZoomClips(atTimelineMs:)`, `duplicateZoomClips(ids:)` methods
- `KeyboardShortcutMonitor.swift` — Cmd+C, Cmd+V, Cmd+D handlers
- `EditorView.swift` — Wire keyboard actions to ClipManager
- `TimelineView.swift` — Selection update after paste, optional paste animation

### Risks

- Cmd+C/V might conflict with system-level pasteboard or text field copy/paste. Since this is a custom view (not a text field), NSEvent monitor should capture it first. May need to check `firstResponder` state.
- Pasting into a region dense with zoom clips could cascade overlaps. Use simple "find next gap" logic rather than shifting all existing clips.
