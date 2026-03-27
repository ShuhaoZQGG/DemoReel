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

---

## 12. NSHostingView in NSPanel — Auto Layout Constraint Crash

**Problem:** `NSGenericException: The window has been marked as needing another Update Constraints in Window pass, but it has already had more Update Constraints in Window passes than there are views in the window.` — app crashes when showing the recording overlay panel.

**Root cause:** `NSHostingView` uses Auto Layout internally and continuously recalculates constraints as SwiftUI state changes (bindings like `elapsedSeconds`, animations like the pulsing dot). When set directly as a borderless panel's `contentView`, the panel's fixed frame and the hosting view's dynamic intrinsic content size fight each other, creating an infinite constraint update loop.

**What didn't work:**
1. Setting `hostingView.frame` + `autoresizingMask` before assigning as contentView — same crash
2. Using `fittingSize` to match panel size to hosting view — still crashes because the hosting view's size changes dynamically with state updates

**Fix:** Wrap the `NSHostingView` in a plain `NSView` container. The wrapper has a fixed frame and serves as the panel's `contentView`. The hosting view is added as a subview with only centering constraints (no width/height constraints that would create cycles):
```swift
let wrapper = NSView(frame: NSRect(origin: .zero, size: panelSize))
hostingView.translatesAutoresizingMaskIntoConstraints = false
wrapper.addSubview(hostingView)
NSLayoutConstraint.activate([
    hostingView.centerXAnchor.constraint(equalTo: wrapper.centerXAnchor),
    hostingView.centerYAnchor.constraint(equalTo: wrapper.centerYAnchor),
])
panel.contentView = wrapper
```

**Lesson:** Never use `NSHostingView` directly as a borderless panel's `contentView` when the SwiftUI content has dynamic state or animations. The wrapper NSView breaks the constraint feedback loop by decoupling the panel's frame management from the hosting view's Auto Layout.

---

## 13. Floating Overlay Panel Persistence After Recording

**Problem:** After clicking "Finish" to end a recording and navigating to the editor, the floating recording bar remained on screen. Doing N recordings would leave N orphaned floating bars.

**Root cause (multi-layered):**

1. **`orderOut` vs `close`:** `dismissOverlay()` originally called `overlayPanel?.orderOut(nil)`, which hides the panel but keeps the `NSPanel` object alive in `NSApplication.shared.windows`. Fixed by using `.close()` instead.

2. **Window restoration loop:** `finishRecording()` iterated over ALL windows with `window.makeKeyAndOrderFront(nil)`, which brought back any overlay panel that hadn't been garbage-collected yet. Fixed by filtering: `where !(window is RecordingOverlayPanel)`.

3. **SwiftUI struct lifecycle (the real root cause):** `RecordingView` is a SwiftUI struct. When the app navigates to `.editor` screen, the struct is destroyed and `@State overlayPanel` is lost. But the actual `NSPanel` window object remains alive in the window server — orphaned with no Swift reference to close it. On the next recording, a new panel is created while the old one lingers.

**Fix:** `dismissOverlay()` now also sweeps all app windows for any `RecordingOverlayPanel` instances and closes them:
```swift
private func dismissOverlay() {
    overlayPanel?.close()
    overlayPanel = nil
    for window in NSApplication.shared.windows where window is RecordingOverlayPanel {
        window.close()
    }
}
```

**Lesson:** When SwiftUI views manage AppKit window objects via `@State`, the window can outlive the SwiftUI view's lifecycle. Always clean up by scanning `NSApplication.shared.windows` rather than relying solely on a stored reference.

---

## 14. Video Editor — Play/Pause Bug After End of Video

**Problem:** Playing a recording works the first time, but after the video reaches the end, pressing Space to play again would instantly jump to the last frame instead of restarting playback.

**Root cause:** When AVPlayer reaches the end of the video, its `timeControlStatus` becomes `.paused` internally, but the editor's `isPlaying` state remains `true`. Pressing Space toggles `isPlaying` to `false` (pausing an already-paused player — no-op), then pressing Space again toggles it to `true` and calls `player.play()`. But since the playhead is at the end, `play()` immediately hits end-of-item and the time observer fires with the final timestamp.

**Fix (two parts):**

1. Observe `AVPlayerItem.didPlayToEndTime` notification to reset `isPlaying = false` when the video naturally ends:
```swift
endObserver = NotificationCenter.default.addObserver(
    forName: .AVPlayerItemDidPlayToEndTime,
    object: newPlayer.currentItem,
    queue: .main
) { _ in
    isPlaying = false
}
```

2. In the `onChange(of: isPlaying)` handler, detect when the player is at the end and seek to the beginning before playing:
```swift
if playing {
    if let item = player?.currentItem {
        let playerTime = player?.currentTime() ?? .zero
        let duration = item.duration
        if duration.isValid, !duration.isIndefinite,
           CMTimeCompare(playerTime, duration) >= 0 {
            player?.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
            currentTime = 0
        }
    }
    player?.play()
}
```

**Lesson:** AVPlayer doesn't auto-reset to the beginning when playback ends. The app must observe `.AVPlayerItemDidPlayToEndTime` and handle the seek-to-start logic explicitly.

---

## 15. Timeline Playhead — Click-Only, No Drag Scrubbing

**Problem:** The timeline playhead only responded to clicks (`.onTapGesture`). Users couldn't drag to scrub through the video — clicking was imprecise and sometimes required multiple clicks.

**Fix:** Replace `.onTapGesture` with `DragGesture(minimumDistance: 0)`, which fires on both taps (zero distance) and drags:
```swift
.gesture(
    DragGesture(minimumDistance: 0)
        .onChanged { value in
            let time = value.location.x / pixelsPerSecond
            currentTime = max(0, min(time, duration))
            if isPlaying { isPlaying = false }
        }
)
```

**Lesson:** `DragGesture(minimumDistance: 0)` is the idiomatic SwiftUI pattern for combined click-and-drag interactions. It supersedes `.onTapGesture` for scrubber/slider-like controls.

---

## 16. Export Pipeline — Unbounded Memory Growth (80 GB+)

**Problem:** Exporting a 40-second recording at 6880x2880 caused memory to grow past 80 GB and never stop, eventually forcing a kill or system hang.

**Root cause (two issues):**

1. **No `autoreleasepool` in frame loop.** The export loop processes ~1200 frames sequentially. Each iteration creates heavyweight Obj-C/Core Graphics objects — `CIImage`, `NSCIImageRep`, `NSImage`, `ImageRenderer`, `CGImage` — that are autoreleased. In a tight `while` loop that never returns to a run loop, these objects accumulate in the default autorelease pool and are never drained until the entire `runExport()` method returns. For 1200 frames of 6880x2880 video, this means tens of thousands of multi-megabyte image objects alive simultaneously.

2. **`CIContext()` created per frame.** `CIContext` is a heavyweight object that allocates GPU resources and internal caches. The old code created a new one for every frame (actually two per frame in the standalone script — one for reading, one for writing). Each `CIContext` retains its caches even after use, so 2400 instances accumulated their GPU buffers.

**Fix:**

1. Wrap the frame loop body in `autoreleasepool { }`. This drains all temporary Obj-C objects at the end of each iteration:
```swift
while let sampleBuffer = videoOutput.copyNextSampleBuffer() {
    autoreleasepool {
        // ... all frame processing ...
    }
}
```
Note: inside the closure, `continue` becomes `return` (equivalent behavior — skips to next iteration).

2. Move `CIContext()` creation outside the loop — one instance reused for all frames:
```swift
let ciCtx = CIContext()  // created once
while let sampleBuffer = videoOutput.copyNextSampleBuffer() {
    autoreleasepool {
        // ... use ciCtx for both createCGImage and render ...
    }
}
```

3. Same `autoreleasepool` treatment for the audio sample loop.

**Result:** Memory stays bounded at ~1.3–2.8 GB (oscillating as frames are processed and released), peak 2.8 GB. Previously grew linearly past 80 GB. Export completes in ~94 seconds for 1189 frames.

**Lesson:** Any tight loop in macOS that creates Obj-C or Core Graphics objects (images, contexts, pixel buffers) MUST wrap the loop body in `autoreleasepool`. Without it, autorelease objects accumulate until the enclosing scope exits. This is especially critical for video processing where each frame creates multiple large image objects. Also, `CIContext` should always be reused — it's designed to be long-lived and amortizes internal setup costs across renders.
