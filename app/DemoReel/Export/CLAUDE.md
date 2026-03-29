# Export Module

Video export pipeline using SwiftUI ImageRenderer for pixel-perfect output.

## Files

- `ExportManager.swift` — Bridges Rust ExportCallback protocol to Swift closures
- `ExportSheet.swift` — Modal config/progress/complete UI; state machine with three views
- `NativeExporter.swift` — Frame-by-frame export: reads source video, renders each frame through SwiftUI, writes MP4

## Key Details

- NativeExporter renders the same SwiftUI view pipeline as preview (ExportFrameView) via ImageRenderer
- ImageRenderer must run on main thread
- Dual timekeeping: zoom keyframes use timeline time, cursor data uses source time
- No audio export — clip reordering makes mixing complex
- Uses autoreleasepool per frame to prevent memory bloat
- Resolution "0" in config means "use source dimensions"
