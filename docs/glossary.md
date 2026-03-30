# DemoReel Glossary

Quick reference for all concepts, structs, and terminology used in the project.

---

## App Screens

| Term | Description |
|------|-------------|
| **Recording** | Screen where user selects a window and records screen + mouse events. |
| **Editor** | Main workspace: preview on top, timeline below, config sidebar on right. |
| **Export** | Sheet for rendering the final video with all effects applied. |

---

## Timeline Concepts

| Term | Description |
|------|-------------|
| **Timeline** | Horizontal scrollable area showing video clips and zoom clips across time. |
| **Playhead** | Red vertical line indicating current position on the timeline. Follows mouse hover when not playing. |
| **Video Track** | Upper track in the timeline showing video `Clip` segments (y: 22–52). |
| **Zoom Track** | Lower track showing `ZoomClip` segments (y: 60–84). |
| **Timeline Position** | Current position on the output timeline (seconds). May differ from source time due to speed changes or cuts. |
| **Source Time** | Position in the original recorded video (seconds). A clip maps a source range to a timeline range. |
| **Pixels Per Second** | Zoom level of the timeline view; controls horizontal scale. |

---

## Clips

| Term | Struct | Description |
|------|--------|-------------|
| **Clip** | `Clip` | A segment of the source video placed on the video track. Has `sourceStartMs`/`sourceEndMs` (range in original video), `speed`, and `timelineStartMs` (where it sits on the output timeline). |
| **ZoomClip** | `ZoomClip` | A zoom effect region on the zoom track. Has `timelineStartMs`, `durationMs`, `centerX`/`centerY` (focus point, 0–1), `scale`, and per-clip ease fields (`easeInMs`, `easeOutMs`, `easeEnabled`). Overlapping zoom clips are allowed. |
| **ClipManager** | `ClipManager` | Central manager that owns both `clips: [Clip]` and `zoomClips: [ZoomClip]`. Handles split, merge, delete, reorder, and coordinate mapping between source and timeline time. |
| **Trim Start / End** | — | Boundaries that define the active region of the recording. Clips outside this range are excluded. |
| **Draggable Focus Point** | — | Visual circle overlay on the preview showing the zoom center of the selected zoom clip. Draggable to reposition; arrow keys nudge it (±10px, Shift ±1px). |
| **MediaItem** | `MediaItem` | A video source in the media pool. Has `id`, `filePath`, `durationMs`, `width`/`height`, `name`. Clips link to media items via `mediaItemId`. |

---

## Clip Operations

| Operation | Description |
|-----------|-------------|
| **Split** | Cut a clip at the playhead into two adjacent clips. Works on both video clips (by source time) and zoom clips (by timeline time). |
| **Merge** | Combine two adjacent magneted clips back into one. |
| **Magnet** | Select multiple clips and snap them together (remove gaps). Visual indicator: purple outline. |
| **Delete** | Remove selected clips from the timeline. |
| **Speed Change** | Alter playback speed of a video clip (e.g., 0.5x, 2x). Affects `playbackDuration` but not `sourceDuration`. |
| **Resize** | Drag left/right edge of a zoom clip to change its start time or duration (min 100ms). |
| **Ease Resize** | When ease is enabled on a zoom clip, drag the inner ease-in/ease-out boundaries to adjust their duration. Ease-in's right edge and ease-out's left edge are draggable. |

---

## Zoom System

| Term | Description |
|------|-------------|
| **ZoomKeyframe** | Auto-generated zoom event from the Rust core. Has `startMs`, `endMs`, `centerX`, `centerY`, `scale`. Generated from mouse click events. |
| **ZoomConfig** | Global configuration for auto-generated zoom keyframes: `scale` (1.0–4.0x), `easeInMs` (default 300ms), `holdMs` (default 600ms), `easeOutMs` (default 400ms), `mergeThresholdMs` (default 300ms, gap below which adjacent zooms merge), `enabled`. Used as fallback when per-clip ease is not enabled. |
| **Per-Clip Ease** | Each `ZoomClip` can override the global ease timing with its own `easeInMs`/`easeOutMs` values when `easeEnabled` is true. The hold duration is computed as `durationMs - easeInMs - easeOutMs`. Toggle via the wave icon in the transport bar when zoom clips are selected. |
| **ZoomClip Placement** | Interactive mode (green shadow) for placing a new zoom clip. Click the `+` button to enter, hover to preview, click to place. Exits after placement. |
| **Zoom Scale** | Magnification level of a zoom clip. Configurable per-clip or globally via ZoomConfig. |
| **Ease Rendering** | When per-clip ease is enabled, the zoom clip displays gradient overlays: translucent-to-solid on the left (ease-in), solid-to-translucent on the right (ease-out), with draggable boundary lines between the ease regions and the hold body. Both preview and export use per-clip ease values via `ClipManager.zoomScaleWithPerClipEase()`. |
| **Cursor-Following Zoom** | During the hold phase, the zoom center dynamically tracks the smoothed cursor position instead of staying fixed. Controlled by `ZoomConfig.follow_cursor`. Blends from static keyframe center during ease-in, follows cursor during hold, holds last cursor position during ease-out. |
| **Activity Session** | A period of cursor activity detected by velocity-based heuristics. Starts with a click, extends while cursor speed exceeds `velocity_threshold` (default 50 px/s), ends after `idle_timeout_ms` (default 1500ms) of inactivity. Used to generate zoom keyframes from natural mouse behavior. |

---

## Editor Modes

| Mode | Activation | Visual | Behavior |
|------|-----------|--------|----------|
| **Scissor Mode** | Press `C` or toolbar button | Blue vertical line + scissors icon follows mouse | Click to split the clip under the cursor. Y-position determines which track (video or zoom). |
| **Zoom Placement Mode** | Click `+` button on toolbar | Green rounded rectangle shadow follows mouse on zoom track | Click to place a 1-second zoom clip at that position. Auto-exits after placement. |

Modes are mutually exclusive — entering one deactivates the other. Press `Escape` to exit either mode.

---

## Styling

| Term | Struct | Description |
|------|--------|-------------|
| **StyleConfig** | `StyleConfig` | Top-level style settings: `background`, `padding`, `cornerRadius`, `shadowEnabled`, `shadowIntensity`, `aspectRatio`. |
| **BackgroundConfig** | `BackgroundConfig` | Background behind the video: `bgType` (solid/gradient), `hex`, gradient colors, gradient angle. |
| **AspectRatioConfig** | `AspectRatioConfig` | Output aspect ratio (e.g., 16:9, 4:3, 1:1). |
| **CursorConfig** | `CursorConfig` | Cursor rendering: `cursorStyle`, `sizeMultiplier`, `clickHighlight` (on/off), `highlightColorHex`. |
| **BackgroundConfig (image)** | `BackgroundConfig` | Extended to support `bg_type: "image"` with `image_name` field for wallpaper backgrounds. |
| **WallpaperCatalog** | `WallpaperCatalog` | 25 bundled macOS/abstract wallpaper images selectable as video backgrounds. |

---

## Media Pool

| Term | Description |
|------|-------------|
| **MediaPoolPanel** | Sidebar panel for importing, previewing, and managing multiple video sources. |
| **Multi-Source Clips** | Clips can reference different video sources via `mediaItemId`. Legacy clips (nil mediaItemId) use the original recording. |

---

## Editor Infrastructure

| Term | Description |
|------|-------------|
| **ThumbnailCache** | `@Observable` LRU cache that generates and stores timeline frame thumbnails asynchronously. Prevents redundant AVAssetImageGenerator work. Uses a `generation` counter to signal SwiftUI updates without observing the entire cache dictionary. |
| **SnapEngine** | Stateless calculator that finds snap targets (other clip edges, playhead, trim bounds) for timeline alignment during drag operations. Prevents clips from snapping to their own edges. |
| **Undo/Redo** | Cmd+Z / Cmd+Y with a 50-step history limit. Slider edits are debounced (500ms) so rapid adjustments produce a single undo entry. Cmd+Shift+Z is an alternative redo shortcut. |

---

## Recording

| Term | Description |
|------|-------------|
| **ScreenRecorder** | Captures screen content using `SCStream` (ScreenCaptureKit). Records to `.mov` file. |
| **EventLogger** | Captures mouse events (moves, clicks, scrolls, drags) via `NSEvent` global/local monitors. Writes JSON log alongside the video. |
| **SmoothedPoint** | A cursor position after smoothing (Exponential Moving Average, alpha=0.3). Used for rendering a smooth cursor path in preview. |
| **RecordingOverlay** | Floating translucent panel (`RecordingOverlayPanel`) showing elapsed time and stop button during recording. Stays above all windows. |
| **SourcePickerCoordinator** | Manages `SCContentSharingPicker` for selecting which window/screen to record. |

---

## Export

| Term | Description |
|------|-------------|
| **NativeExporter** | Pure Swift/AVFoundation export pipeline. Reads source video frame-by-frame, applies zoom/pan transforms, composites cursor, renders styled background, and writes to output `.mov`. |
| **ExportManager** | Manages export state (progress, cancellation) and coordinates the export UI. |
| **Export Formats** | MP4 (H.264/libx264), WebM (VP9/libvpx-vp9), and GIF. Format selection in ExportSheet; Rust core builds format-specific FFmpeg args. GIF has no audio track. |

---

## Keyboard Shortcuts

| Key | Action | Scope |
|-----|--------|-------|
| `Space` | Play / Pause | Editor (via `.keyboardShortcut`) |
| `C` | Toggle Scissor Mode | Editor (via `KeyboardShortcutMonitor`) |
| `Z` | Add zoom clip at playhead | Editor (via `KeyboardShortcutMonitor`) |
| `Delete` / `Backspace` | Delete selected clips | Editor (via `KeyboardShortcutMonitor`) |
| `Escape` | Exit scissor/placement mode | Editor (via `KeyboardShortcutMonitor`) |
| `Cmd+S` | Save project | Global (menu command) |
| `Cmd+E` | Export video | Global (menu command) |
| `Cmd+N` | New recording | Global (menu command) |
| `Cmd+O` | Open project | Global (menu command) |
| `Cmd+Z` | Undo | Global (via `KeyboardShortcutMonitor`) |
| `Cmd+Y` / `Cmd+Shift+Z` | Redo | Global (via `KeyboardShortcutMonitor`) |
| `Cmd+D` | Duplicate selection | Editor (via `KeyboardShortcutMonitor`) |
| `Tab` / `Shift+Tab` | Select next / previous zoom clip | Editor (via `KeyboardShortcutMonitor`) |
| `[` / `]` | Adjust zoom duration (±200ms, Shift ±50ms) | Editor (via `KeyboardShortcutMonitor`) |
| `=` / `-` | Adjust zoom scale (±0.25) | Editor (via `KeyboardShortcutMonitor`) |
| `,` / `.` | Nudge zoom position (±100ms, Shift ±25ms) | Editor (via `KeyboardShortcutMonitor`) |
| Arrow keys | Nudge focus point (±10px, Shift ±1px) | Editor (via `KeyboardShortcutMonitor`) |

**KeyboardShortcutMonitor** — An `@Observable` class that installs an `NSEvent` local monitor for `.keyDown` events. Catches bare keystrokes (no modifiers) regardless of which view has focus. Publishes actions via `lastAction` which EditorView observes with `.onChange`. Skips interception when a sheet is presented.

---

## Project File

| File | Description |
|------|-------------|
| `.demoreel` | Main project file (JSON). Stores video/events paths, all config values (zoom, style, cursor, trim), and metadata (name, version, createdAt). |
| `.demoreel.clips.json` | Sidecar file storing the `[Clip]` array (video clip segments). |
| `.demoreel.zoomclips.json` | Sidecar file storing the `[ZoomClip]` array (zoom effect regions). |

Recordings are saved to `~/Movies/DemoReel/`.
