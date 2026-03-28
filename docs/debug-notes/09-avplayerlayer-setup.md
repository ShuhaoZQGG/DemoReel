# 9. AVPlayerLayer Setup

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
