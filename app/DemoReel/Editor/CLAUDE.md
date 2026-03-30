# Editor Module

Timeline editing, video preview, and configuration panels.

## Files

- `EditorView.swift` — Main editor container; timer-driven playback at 30 FPS, project save/load
- `TimelineView.swift` — Two-track timeline: video clips (top) and zoom clips (bottom); trim handles, scrubbing
- `PreviewView.swift` — AVPlayer seek-based preview with zoom, style, and cursor overlays
- `ZoomKeyframeEditor.swift` — Zoom clip track with drag-move, edge-resize, and scissor split
- `StylePanel.swift` — Background (solid/gradient), padding, corner radius, shadow, aspect ratio
- `CursorPanel.swift` — Cursor style (circle/system/hidden), size, click highlight color
- `Clip.swift` — Data model: sourceStartMs/sourceEndMs/timelineStartMs/speed
- `ClipManager.swift` — Central state for clips and zoom clips; time mapping, split/merge, zoom interpolation
- `ZoomClip.swift` — Data model: zoom effect with center, scale, and per-clip ease-in/out
- `KeyboardShortcutMonitor.swift` — Bare-key shortcuts (C=scissor, Z=zoom, Delete, Escape) via NSEvent monitor
- `ThumbnailCache.swift` — @Observable LRU cache for timeline frame thumbnails
- `SnapEngine.swift` — Stateless snap target calculator for timeline clip alignment
- `MediaItem.swift` — Data model for video sources in the media pool
- `MediaPoolPanel.swift` — Sidebar panel for importing and managing video sources
- `WallpaperCatalog.swift` — 25 bundled macOS/abstract wallpaper background definitions

## Key Concepts

- Three time spaces: source time (original video), timeline time (edited output), playback duration (speed-adjusted)
- Preview uses seek-based playback (AVPlayer always paused; timer calls seek)
- ClipManager.sourceTimeForTimelinePosition() maps timeline→source; returns nil in gaps
- All times internally in milliseconds (UInt64)
- Config objects (StyleConfig, ZoomConfig, CursorConfig) are immutable value types; recreated on each change
- Undo/redo: Cmd+Z / Cmd+Y, 50-step limit, slider edits are debounced before snapshotting
- Media pool allows importing multiple video sources; MediaItem represents each source
- ThumbnailCache provides async thumbnail generation with LRU eviction for timeline rendering
- SnapEngine computes snap targets so clips align to other clip edges and the playhead
