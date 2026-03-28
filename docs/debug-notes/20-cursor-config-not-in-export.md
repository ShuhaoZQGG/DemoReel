# 20 — Cursor config not applied in export

**Symptom:** Changing cursor style/size in the editor sidebar renders correctly in the preview, but the exported video shows the system default cursor at 1x size.

**Root causes (two issues):**

1. **Canvas doesn't render in ImageRenderer.** `ExportFrameView.cursorOverlay` used a SwiftUI `Canvas` to draw the cursor. `Canvas` renders fine in the live view hierarchy (preview) but produces no output when rasterized through `ImageRenderer` (export pipeline). The custom cursor was simply absent from exported frames.

2. **`.sheet` closure captured stale config values.** `ExportSheet` received `zoomConfig`, `styleConfig`, and `cursorConfig` as `let` values. SwiftUI's `.sheet(isPresented:)` content closure can cache the view tree from an earlier render cycle, so config changes made after the initial capture (e.g., changing size after changing style) were lost by export time.

**Fix:**

1. Replaced `Canvas { context, size in ... }` with `GeometryReader` + standard SwiftUI views (`Circle`, `SystemCursorView`) in both `ExportFrameView` and `PreviewView`. These render correctly through `ImageRenderer`.

2. Changed `ExportSheet` to accept the three configs as `@Binding` instead of `let`, so it always reads the latest values at export time.

**Lesson:** `Canvas` is an immediate-mode drawing view that works on-screen but is not reliably rasterized by `ImageRenderer`. For views that must render both on-screen and through `ImageRenderer`, use standard retained-mode SwiftUI views. Pass mutable state into `.sheet` content via `@Binding` to avoid stale captures.
