# Plan: Easing Curve Selection

**Priority:** 7 (Medium)
**Status:** Planned
**Scope:** core/zoom.rs + types.rs + ZoomClip + UI

## Problem

Zoom transitions use a hardcoded cubic ease-in-out curve (`cubic_ease_in_out` in `zoom.rs`). All zooms feel the same. Screen Studio offers multiple curve options (linear, ease-in, ease-out, ease-in-out, spring) for more expressive control.

## Approach

Add an `EasingCurve` enum to the core types and use it per-zoom-clip. Start with 3-4 curves, not a full bezier editor.

### Implementation Steps

1. **`EasingCurve` enum in `types.rs`** — Define variants: `Linear`, `EaseInOut` (current default), `EaseIn`, `EaseOut`, `Spring`. Derive Serialize/Deserialize. Expose via UniFFI.

2. **Easing functions in `zoom.rs`** — Add `ease_in`, `ease_out`, `linear`, and `spring` functions alongside existing `cubic_ease_in_out`. Add a dispatch function `apply_easing(curve: EasingCurve, t: f64) -> f64`.

3. **Per-clip easing on `ZoomClip`** — Add `easingCurve: EasingCurve` field (default `.easeInOut`). Wire through `ClipManager.zoomScaleWithPerClipEase` to pass the curve to the Rust computation.

4. **UI picker** — When a zoom clip is selected, show a segmented control or small menu in the transport bar with curve icons (straight line, S-curve, bounce). Update `easingCurve` on the selected clip.

5. **Visual hint on ZoomClipView** — Optionally draw a tiny curve icon (2-3px stroke) inside the ease-in/ease-out regions to indicate which curve is active.

6. **Project serialization** — Add `easingCurve` to ZoomClip's serialization in `project.rs`. Default to `EaseInOut` for backward compatibility.

### Files to Modify

- `core/src/types.rs` — Add `EasingCurve` enum
- `core/src/zoom.rs` — Add easing functions, `apply_easing` dispatcher, update `zoom_scale_at`
- `core/src/project.rs` — Serialize/deserialize new field
- `core/src/lib.rs` — Export new enum via UniFFI if needed
- `app/DemoReel/Editor/ZoomClip.swift` — Add `easingCurve` property
- `app/DemoReel/Editor/ClipManager.swift` — Pass curve through to Rust
- `app/DemoReel/Editor/TimelineView.swift` — Curve picker UI
- `app/DemoReel/Editor/ZoomKeyframeEditor.swift` — Optional curve icon in clip view

### Risks

- Spring easing is more complex (needs damping/stiffness parameters). Start with a single "spring" preset, don't expose parameters initially.
- UniFFI enum export needs `#[derive(uniffi::Enum)]` — verify it generates correctly for Swift.
- Backward compatibility: old project files won't have the field. Use `#[serde(default)]` in Rust.
