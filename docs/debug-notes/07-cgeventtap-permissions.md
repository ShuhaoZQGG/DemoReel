# 7. CGEventTap — Permission Issues

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
