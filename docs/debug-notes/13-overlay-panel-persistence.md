# 13. Floating Overlay Panel Persistence After Recording

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
