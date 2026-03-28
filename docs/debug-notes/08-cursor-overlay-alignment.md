# 8. SwiftUI + NSViewRepresentable — Cursor Overlay Alignment

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
