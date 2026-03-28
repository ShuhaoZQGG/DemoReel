# 19. Per-Clip Ease-In/Out — Stored But Not Applied

**Problem:** Per-clip `easeInMs`/`easeOutMs`/`easeEnabled` values were stored in `ZoomClip` and visually resizable on the timeline, but had no effect on preview or export playback.

**Root cause (architectural disconnect):**

```
ZoomClip (editable, has easeInMs/easeOutMs/easeEnabled)
    ↓ ClipManager.zoomKeyframesForPreview()
ZoomKeyframe (immutable, NO ease fields)
    ↓ passed to Preview/Export
zoomScaleAt(keyframes, timestampMs, config)  ← uses GLOBAL ZoomConfig ease values
```

The conversion from `ZoomClip` → `ZoomKeyframe` stripped away all per-clip ease values. The Rust `zoomScaleAt()` function only accepted a global `ZoomConfig` — no mechanism existed to override with per-clip settings.

**Fix:** Added a Swift-side helper `ClipManager.zoomScaleWithPerClipEase()` that:
1. Finds the zoom clip containing the given timestamp
2. If `easeEnabled`: constructs a per-clip `ZoomConfig` with the clip's `easeInMs`/`easeOutMs` and computed `holdMs = durationMs - easeInMs - easeOutMs`, then calls the Rust `zoomScaleAt()`
3. If not `easeEnabled`: calls `zoomScaleAt()` with the global config as-is

Both `PreviewView` and `NativeExporter` now receive `zoomClips: [ZoomClip]` and call this helper instead of `zoomScaleAt()` directly.

**Also fixed — ease-out visual drag direction:**
The ease-out resize showed the region expanding in the opposite direction from the drag. Root cause: dragging the ease-out boundary left (negative `resizeOffset`) should visually grow the region, but the offset was applied directly (shrinking it). Fix: negate the visual offset for ease-out: `return -resizeOffset`.

**Lesson:** When adding per-item overrides to a system that uses global config, trace the entire data flow from storage → conversion → rendering. The conversion layer (`zoomKeyframesForPreview()`) was silently discarding the new fields. The fix didn't require modifying the Rust core — a Swift-side wrapper that constructs per-call configs was sufficient.
