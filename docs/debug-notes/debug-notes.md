# DemoReel Debug Notes

Lessons learned during development, covering macOS screen recording, coordinate systems, event capture, and SwiftUI/AppKit interop.

Each note is in its own file under `debug-notes/`.

## Build & Project Setup
- [01 — Rust Build Pipeline (UniFFI + Static Library)](docs/debug-notes/01-rust-build-pipeline.md)
- [02 — UniFFI Bindgen Setup](docs/debug-notes/02-uniffi-bindgen.md)
- [03 — Xcode Project Generation (xcodegen)](docs/debug-notes/03-xcode-project-generation.md)

## Screen Recording & Capture
- [04 — Screen Recording — AVAssetWriter + ScreenCaptureKit](docs/debug-notes/04-screen-recording.md)
- [05 — Video Capture — Window Positioning in Frame](docs/debug-notes/05-window-positioning.md)
- [06 — macOS Coordinate Systems](docs/debug-notes/06-coordinate-systems.md)
- [07 — CGEventTap — Permission Issues](docs/debug-notes/07-cgeventtap-permissions.md)
- [10 — SCContentSharingPicker — Native Source Selection](docs/debug-notes/10-sccontentsharingpicker.md)

## SwiftUI / AppKit Interop
- [08 — Cursor Overlay Alignment](docs/debug-notes/08-cursor-overlay-alignment.md)
- [09 — AVPlayerLayer Setup](docs/debug-notes/09-avplayerlayer-setup.md)
- [11 — Floating Recording Controls](docs/debug-notes/11-floating-recording-controls.md)
- [12 — NSHostingView in NSPanel — Constraint Crash](docsdebug-notes/12-nshostingview-constraint-crash.md)
- [13 — Floating Overlay Panel Persistence](docsdebug-notes/13-overlay-panel-persistence.md)

## Editor & Timeline
- [14 — Play/Pause Bug After End of Video](docsdebug-notes/14-play-pause-end-of-video.md)
- [15 — Timeline Playhead — No Drag Scrubbing](docs/debug-notes/15-timeline-scrubbing.md)
- [18 — Keyboard Shortcuts — "Ding" Sound, Keys Ignored](docs/debug-notes/18-keyboard-shortcuts-ding.md)

## Export Pipeline
- [16 — Unbounded Memory Growth (80 GB+)](docs/debug-notes/16-export-memory-growth.md)
- [17 — Export Ignores All Editor Edits](docs/debug-notes/17-export-ignores-edits.md)
- [20 - cursor-config-not-in-export](docs/debug-notes/20-cursor-config-not-in-export.md)

## Zoom & Easing
- [19 — Per-Clip Ease-In/Out — Stored But Not Applied](docs/debug-notes/19-per-clip-ease-not-applied.md)

## Timeline Thumbnails
- [21 — ThumbnailCache — @Observable Infinite Re-render Loop](docs/debug-notes/21-thumbnail-cache-infinite-rerender.md)

