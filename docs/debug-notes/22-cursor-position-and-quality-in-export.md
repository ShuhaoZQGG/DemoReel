# 22 — Cursor position and quality wrong in export during zoom

**Symptom:** In the exported video, the cursor drifts to the top-left corner during zoom state instead of following the viewport center as it does in the preview. Additionally, the cursor appears smaller and lower quality (jagged edges, blurry system cursor) compared to the preview.

**Root causes (two issues):**

1. **Cursor normalized against wrong dimensions.** `ExportFrameView` received `clipVideoW` / `clipVideoH` (from `AVAssetTrack.naturalSize` — pixel dimensions, e.g., 3840x2160 on Retina) for cursor position normalization. But cursor events are recorded in logical screen coordinates (`screenW` / `screenH`, e.g., 1920x1080). The zoom anchor correctly used `screenW`/`screenH`, but the cursor overlay computed `fracX = point.x / clipVideoW`, producing a fraction half the correct value on Retina — pushing the cursor toward the top-left.

2. **ImageRenderer at 1x scale.** `renderOnMain` used `renderer.scale = 1.0`, meaning 1 SwiftUI point = 1 pixel. The Retina preview renders at 2x natively. This caused: (a) vector shapes (Circle, shadows) to render with 1x anti-aliasing; (b) `NSCursor.arrow.image` to use its 1x representation instead of the sharp 2x variant; (c) cursor size appearing too small relative to video content since the export render area (in points) is much larger than the preview container.

**Fix:**

1. Changed `NativeExporter` to pass `screenW`/`screenH` (from the event log) instead of `clipVideoW`/`clipVideoH` to `ExportFrameView` for video frames. This matches the preview path, where `EditorView` sets `videoWidth`/`videoHeight` from `parseEventLog().screenWidth`/`.screenHeight`. Gap frames already correctly used `screenW`/`screenH`.

2. Changed `renderer.scale` from `1.0` to `2.0` and added a CGContext downscale step with `.high` interpolation quality, producing output-sized frames with supersampled cursor rendering.

3. Scaled cursor `baseSize` in `ExportFrameView.cursorOverlay` by `geo.size.width / videoWidth` to match the proportional size seen in preview, since the export layout space is much larger than the preview container.

**Lesson:** Cursor event data is in logical screen coordinates, not video pixel coordinates — always normalize against `screenWidth`/`screenHeight` from the event log, not `AVAssetTrack.naturalSize`. When using `ImageRenderer` for export, set `renderer.scale = 2.0` to match Retina preview quality for vector elements and `NSImage` representations. The preview and export coordinate spaces differ in scale; cursor sizing must account for the ratio between the export render area and the logical screen dimensions.
