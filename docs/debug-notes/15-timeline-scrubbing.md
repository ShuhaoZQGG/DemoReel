# 15. Timeline Playhead — Click-Only, No Drag Scrubbing

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
