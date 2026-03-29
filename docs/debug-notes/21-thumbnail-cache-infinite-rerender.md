# 21. ThumbnailCache — @Observable Infinite Re-render Loop

**Problem:** Editor froze completely (UI unresponsive, no errors) immediately after adding a `ThumbnailCache` that generates video frame thumbnails for timeline clip segments. No crash, no error — just a frozen app consuming 100% CPU.

**Root cause:** Classic SwiftUI `@Observable` infinite re-render loop. The `thumbnails()` method was called from inside the view body (via `ClipSegmentView`), and it had a side effect: when it found missing thumbnails, it called `requestThumbnails()` inline. This created a cycle:

1. View renders → calls `thumbnails(for: clip, ...)` → finds missing entries → calls `requestThumbnails()`
2. Background task generates one thumbnail → writes to `@Observable` `cache` dict on MainActor
3. SwiftUI detects mutation → schedules re-render of every `ClipSegmentView`
4. View renders again → calls `thumbnails()` → cancels old task (some thumbnails still missing) → starts new `requestThumbnails()`
5. Goto 2 — infinite loop, tasks constantly cancelled and restarted, never completing

Three compounding issues:
- **Side effects in render path:** `thumbnails()` triggered async work, violating the principle that view body computation must be pure.
- **Observed dictionary:** `private(set) var cache: [ThumbnailKey: NSImage]` was observed by SwiftUI. Every single thumbnail insert (potentially hundreds) triggered a full re-render of the timeline.
- **LRU touch in read path:** `touchKey()` mutated `accessOrder` during reads, also triggering re-renders.

**Fix (three changes):**

1. **Pure read function:** `thumbnails()` now only returns what's cached — no side effects, no generation triggers. It reads a `generation` counter (an `Int`) to establish a SwiftUI observation dependency, but never mutates state.

2. **Generation counter instead of observed dict:** Replaced observing the entire `cache` dictionary with a single `private(set) var generation: Int`. The counter increments once per completed clip (not per thumbnail), so SwiftUI re-renders at most N times for N clips, not hundreds of times for hundreds of thumbnails. The `cache` dict itself is unobserved internal storage.

3. **Explicit trigger points:** Thumbnail requests are kicked off from `.task` (on appear) and `.onChange(of: pixelsPerSecond)` (on zoom change) — never from inside the render path. A `pendingClips` set prevents duplicate requests.

**Key lesson:** With `@Observable`, any mutation to any stored property inside the class triggers re-renders for every view that read any property during its last body evaluation. In a timeline with many clips, a dict mutation per thumbnail creates a re-render storm. The fix pattern: use a cheap observed "version counter" and keep the expensive data structure unobserved.

**Files:** `ThumbnailCache.swift`, `TimelineView.swift`
