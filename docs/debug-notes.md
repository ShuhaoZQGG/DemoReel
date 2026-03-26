# DemoReel Debug Notes

Lessons learned during development, covering macOS screen recording, coordinate systems, event capture, and SwiftUI/AppKit interop.

---

## 1. Rust Build Pipeline (UniFFI + Static Library)

**Problem:** `lipo` failed creating universal binary — no `.a` file produced.

**Root cause:** `Cargo.toml` had `crate-type = ["cdylib", "lib"]` — missing `"staticlib"`. Without it, cargo only produces `.dylib` and rlib, not the `.a` file that `lipo` expects for universal binaries.

**Fix:** Add `"staticlib"` to crate-type:
```toml
crate-type = ["cdylib", "staticlib", "lib"]
```

**Lesson:** UniFFI needs `cdylib` for the dynamic library (used by bindgen) AND `staticlib` for the static library (linked into the Xcode project).

---

## 2. UniFFI Bindgen Setup

**Problem:** `cargo run --bin uniffi-bindgen` failed — no binary target found.

**Root cause:** UniFFI 0.28 with proc-macro exports (`#[uniffi::export]`) requires an in-project bindgen binary. The old approach of `cargo run --features uniffi/cli` doesn't work.

**Fix:** Create `core/src/bin/uniffi-bindgen.rs`:
```rust
fn main() {
    uniffi::uniffi_bindgen_main()
}
```

**Also:** UniFFI can't handle `Result<T, String>` as a return type. Must use a proper error enum:
```rust
#[derive(uniffi::Error, thiserror::Error, Debug)]
pub enum ParseError {
    #[error("Invalid JSON: {message}")]
    InvalidJson { message: String },
}
```

---

## 3. Xcode Project Generation (xcodegen)

**Problem:** No `.xcodeproj` file existed — only Swift source files.

**Solution:** Use `xcodegen` with a `project.yml` that configures:
- `LIBRARY_SEARCH_PATHS` → point to `core/target/universal`
- `SWIFT_INCLUDE_PATHS` → point to `Generated/` (for FFI modulemap)
- `OTHER_LDFLAGS` → `-ldemoreel_core`
- `OTHER_SWIFT_FLAGS` → `-Xcc -fmodule-map-file=...DemoReelCoreFFI.modulemap`

**Key lesson:** Since the generated `DemoReelCore.swift` is compiled in the same module as the app, `import DemoReelCore` must be removed from all Swift files. The `#if canImport(DemoReelCoreFFI)` in the generated code handles the FFI import.

---

## 4. Screen Recording — AVAssetWriter + ScreenCaptureKit

**Problem:** All `.mov` files were 0 bytes or corrupt (missing moov atom).

**Root cause:** ScreenCaptureKit delivers raw `BGRA` pixel buffers via `CMSampleBuffer`, but `AVAssetWriterInput` configured for H.264 can't directly accept raw pixel data via `input.append(sampleBuffer)`.

**Fix:** Use `AVAssetWriterInputPixelBufferAdaptor`:
```swift
let adaptor = AVAssetWriterInputPixelBufferAdaptor(
    assetWriterInput: input,
    sourcePixelBufferAttributes: [...]
)
// In the stream output callback:
guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
adaptor.append(pixelBuffer, withPresentationTime: timestamp)
```

**Lesson:** `CMSampleBuffer` from ScreenCaptureKit contains raw pixel data, not encoded video. Must extract `CVPixelBuffer` and feed through an adaptor.

---

## 5. Video Capture — Window Positioning in Frame

**Problem:** Recorded window appeared at its screen position within a larger canvas (top-left with black space).

**Root cause:** `SCContentFilter` from the picker captures the window at its display position. Without `scalesToFit`, the output frame is sized to the window but content isn't scaled to fill it.

**Fix:** Set `config.scalesToFit = true` on `SCStreamConfiguration`. Do NOT set `sourceRect` — that crops to wrong coordinates.

**Lesson:** `SCStreamConfiguration.sourceRect` uses the source's internal coordinate space, which differs from screen coordinates. `scalesToFit = true` alone is sufficient.

---

## 6. macOS Coordinate Systems (The Big One)

macOS has multiple coordinate systems that are easy to confuse:

| API | Origin | Y Direction | Name |
|-----|--------|-------------|------|
| `NSEvent.mouseLocation` | Bottom-left of primary display | Up | AppKit screen coords |
| `CGEvent.location` | Top-left of primary display | Down | Quartz screen coords |
| `kCGWindowBounds` | Top-left of primary display | Down | Quartz screen coords |
| `SCContentFilter.contentRect` | Top-left of primary display | Down | CG display coords |
| `NSWindow.frame` | Bottom-left of primary display | Up | AppKit screen coords |
| `NSScreen.frame` | Bottom-left of primary display | Up | AppKit screen coords |

**Key conversion:** AppKit Y → Quartz Y:
```swift
let quartzY = NSScreen.main!.frame.height - appKitY
```

**The critical lesson we learned:** `SCContentFilter.contentRect.origin` is in the SAME coordinate system as `kCGWindowBounds` (Quartz, top-left origin). We confirmed this by logging both and seeing they match exactly:
```
[captureRect] origin=(741.0, 255.0)
[CGWindowList] X=741.0 Y=255.0
```

So the correct conversion for `NSEvent.mouseLocation` to window-relative coords:
```swift
let quartzY = screenHeight - mouseLocation.y
let relX = mouseLocation.x - captureRect.origin.x
let relY = quartzY - captureRect.origin.y
```

**Mistakes we made along the way:**
1. Assumed `contentRect` was bottom-left origin → applied unnecessary Y-flip → wrong offset
2. Tried `CGWindowListCopyWindowInfo` to find the window → picked wrong window after DemoReel was reactivated
3. Tried min-based normalization from event data → used cursor extremes instead of actual window edges

---

## 7. CGEventTap — Permission Issues

**Problem:** CGEventTap only captured events from DemoReel's own windows, not from the recorded app. All events bunched in the last ~1 second (when user switched back to DemoReel).

**Root cause:** `CGEvent.tapCreate` with `.cgSessionEventTap` requires **Accessibility permission** (and possibly **Input Monitoring** on newer macOS) to capture events from other apps. Without it, the tap silently filters out cross-app events.

**What didn't work:**
- Adding `.tapDisabledByTimeout` handler — the tap wasn't timing out, it just wasn't receiving events
- Granting Accessibility permission — still didn't work (may also need Input Monitoring, or the Xcode debug build has a different identity)

**Fix:** Replace CGEventTap with `NSEvent` monitors:
```swift
// Events from OTHER apps (no special permissions needed)
NSEvent.addGlobalMonitorForEvents(matching: mask) { event in ... }

// Events from THIS app
NSEvent.addLocalMonitorForEvents(matching: mask) { event in ... return event }
```

**Lesson:** `NSEvent.addGlobalMonitorForEvents` is far more reliable than CGEventTap for monitoring mouse events across apps. It doesn't require Accessibility or Input Monitoring permissions for basic mouse tracking.

---

## 8. SwiftUI + NSViewRepresentable — Cursor Overlay Alignment

**Problem:** Cursor overlay didn't move with the video when the DemoReel window was resized. The cursor stayed stationary while the video content moved.

**What didn't work:**
- `.overlay { GeometryReader }` on `NSViewRepresentable` — the overlay didn't track size changes
- `Canvas` in `.overlay` — same issue, Canvas size stayed fixed
- Using outer `GeometryReader` `geo.size` — coupled cursor to window size, not video size

**Root cause:** `.overlay` on an `NSViewRepresentable` doesn't reliably resize with SwiftUI layout changes. The overlay's coordinate space is disconnected from the NSView's internal layout.

**Fix:** Put video and cursor in a **shared `ZStack` with an explicit frame** computed from the video's aspect ratio:
```swift
let renderW = videoAspect > viewAspect ? availW : availH * videoAspect
let renderH = videoAspect > viewAspect ? availW / videoAspect : availH

ZStack {
    VideoPlayerView(player: player)  // NSViewRepresentable
    cursorCanvasView                 // Pure SwiftUI Canvas
}
.frame(width: renderW, height: renderH)
```

The Canvas draws the cursor at `(fracX * size.width, fracY * size.height)`. Since both the Canvas and VideoPlayerView share the same `.frame()`, they always have identical bounds. When the window resizes, the frame recomputes and both resize together.

**Lesson:** When combining `NSViewRepresentable` with SwiftUI overlays, don't rely on `.overlay` for pixel-precise alignment. Use a shared `ZStack` with explicit frame sizing instead.

---

## 9. AVPlayerLayer Setup

**Problem:** Video appeared at top-left of the preview instead of centered.

**Approaches tried:**
1. `layer = AVPlayerLayer()` (replacing root layer) — doesn't work, AppKit overrides it
2. `addSublayer` + `layout()` override — `layout()` doesn't fire reliably in NSViewRepresentable
3. `makeBackingLayer()` override — didn't work either
4. `addSublayer` + `autoresizingMask = [.layerWidthSizable, .layerHeightSizable]` — works!

**Final approach:**
```swift
class PlayerNSView: NSView {
    private let playerLayer = AVPlayerLayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        playerLayer.videoGravity = .resizeAspect
        playerLayer.backgroundColor = CGColor.clear
        playerLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        layer?.addSublayer(playerLayer)
        playerLayer.frame = bounds
    }
}
```

**Lesson:** `autoresizingMask` on sublayers is more reliable than `layout()` overrides in NSViewRepresentable contexts, because it uses Core Animation's built-in resizing rather than depending on AppKit layout callbacks.

---

## 10. SCContentSharingPicker — Native Source Selection

**Problem:** Dropdown picker listing all windows was clunky and showed irrelevant items.

**Fix:** Use `SCContentSharingPicker` (macOS 14+) — the system-native picker that shows a transparent overlay. Users click a window or display to select it, same as QuickTime.

**Implementation notes:**
- Conform to `SCContentSharingPickerObserver`
- Call `picker.isActive = true` then `picker.present()`
- The delegate callback `contentSharingPicker(_:didUpdateWith:for:)` returns the `SCContentFilter`
- Must set `picker.isActive = false` after selection or cancellation
- The returned filter works directly with `SCStream`

---

## 11. Floating Recording Controls

**Implementation:** `NSPanel` subclass with:
- `.borderless` + `.nonactivatingPanel` style masks — no title bar, doesn't steal focus
- `.floating` level — stays above all windows
- `isMovableByWindowBackground = true` — draggable
- `hidesOnDeactivate = false` — stays visible when app is in background
- Hosts a SwiftUI view via `NSHostingView`

**Key:** `.nonactivatingPanel` is critical — without it, clicking the stop button would activate DemoReel and steal focus from the recorded window.
