# 16. Export Pipeline — Unbounded Memory Growth (80 GB+)

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
