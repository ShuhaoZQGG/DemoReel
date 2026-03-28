# 6. macOS Coordinate Systems (The Big One)

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
