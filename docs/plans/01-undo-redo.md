# Plan: Undo/Redo System

**Priority:** 1 (Critical)
**Status:** Planned
**Scope:** ClipManager + EditorView

## Problem

Every mutation (split, move, delete, scale change, ease toggle) is permanent until the user reloads the project file. Users are afraid to experiment because there's no way to revert mistakes.

## Approach

Command-pattern undo stack on `ClipManager`. Snapshot the full state (clips + zoomClips) before each mutation, push onto an undo stack. Redo stack holds states popped by undo.

### Implementation Steps

1. **State snapshot type** — Create a `ClipManagerSnapshot` struct holding `[Clip]` and `[ZoomClip]` (both are value types, so copies are cheap).

2. **Undo/redo stacks on ClipManager** — Add `undoStack: [ClipManagerSnapshot]` and `redoStack: [ClipManagerSnapshot]` properties. Cap at ~50 entries to bound memory.

3. **`saveUndoState()` method** — Call before every mutating operation (split, merge, delete, move, scale change, ease toggle, addZoomClip, etc.). Pushes current state onto undoStack, clears redoStack.

4. **`undo()` / `redo()` methods** — Swap current state with the top of the appropriate stack.

5. **Wire up keyboard shortcuts** — Cmd+Z for undo, Cmd+Shift+Z for redo in `KeyboardShortcutMonitor.swift`.

6. **Transport bar buttons** — Add undo/redo buttons (arrow.uturn.backward / arrow.uturn.forward) to the transport bar, disabled when stack is empty.

### Files to Modify

- `ClipManager.swift` — Add snapshot type, stacks, saveUndoState/undo/redo methods, insert saveUndoState() calls before mutations
- `KeyboardShortcutMonitor.swift` — Add Cmd+Z / Cmd+Shift+Z handlers
- `TimelineView.swift` — Add undo/redo buttons to transport bar
- `EditorView.swift` — Wire up undo/redo actions

### Risks

- State snapshot approach is simple but won't scale if ClipManager grows large state (thousands of clips). Unlikely for a screen recorder.
- Must ensure every mutation path calls `saveUndoState()` — easy to miss new ones added later.

### Alternatives Considered

- Per-field diffing: more memory efficient but much more complex. Overkill for this use case.
- Core Data with built-in undo: wrong architecture for this app.
