# Plan: Keyboard-Driven Zoom Clip Workflow

**Priority:** 5 (Medium)
**Status:** Planned
**Scope:** KeyboardShortcutMonitor + TimelineView + ClipManager

## Problem

Adding a zoom clip requires: click "+" button → hover to position → click to place. For demo recordings, users want a fast keyboard-only workflow: park playhead, press a key, adjust with keys.

## Approach

Add keyboard shortcuts for creating and adjusting zoom clips without touching the mouse.

### Implementation Steps

1. **Quick-add zoom at playhead** — Press `Z` (when not in zoom placement mode) to instantly create a 1s zoom clip centered at the current cursor position, starting at the playhead. No placement mode needed.

2. **Adjust duration with `[` / `]`** — When a zoom clip is selected, `[` shrinks duration by 200ms (min 200ms), `]` extends by 200ms. Shift+`[`/`]` for 50ms fine adjustment.

3. **Adjust scale with `+` / `-`** — When a zoom clip is selected, `+` increases scale by 0.25x, `-` decreases by 0.25x. Range: 1.25x to 5.0x.

4. **Nudge position with `,` / `.`** — Move the selected zoom clip left/right by 100ms. Shift+`,`/`.` for 25ms fine nudge.

5. **Duplicate with Cmd+D** — Duplicate selected zoom clip(s), placing copies immediately after the originals.

6. **Select next/previous zoom clip** — Tab / Shift+Tab to cycle through zoom clips in timeline order.

### Files to Modify

- `KeyboardShortcutMonitor.swift` — Add all new key handlers
- `ClipManager.swift` — Add `duplicateZoomClips(ids:)` method
- `EditorView.swift` — Wire up keyboard actions to ClipManager mutations
- `TimelineView.swift` — Support programmatic selection changes from keyboard navigation

### Risks

- Key conflicts with existing shortcuts. `Z` is already used for zoom placement toggle — change to: `Z` without placement mode = quick-add, `Z` with placement mode = cancel placement.
- Must handle the case where the playhead is in a gap (no cursor position available for center). Fall back to video center (0.5, 0.5).
