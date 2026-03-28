# 5. Video Capture — Window Positioning in Frame

**Problem:** Recorded window appeared at its screen position within a larger canvas (top-left with black space).

**Root cause:** `SCContentFilter` from the picker captures the window at its display position. Without `scalesToFit`, the output frame is sized to the window but content isn't scaled to fill it.

**Fix:** Set `config.scalesToFit = true` on `SCStreamConfiguration`. Do NOT set `sourceRect` — that crops to wrong coordinates.

**Lesson:** `SCStreamConfiguration.sourceRect` uses the source's internal coordinate space, which differs from screen coordinates. `scalesToFit = true` alone is sufficient.
