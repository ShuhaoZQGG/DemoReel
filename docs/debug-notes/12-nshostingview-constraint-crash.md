# 12. NSHostingView in NSPanel — Auto Layout Constraint Crash

**Problem:** `NSGenericException: The window has been marked as needing another Update Constraints in Window pass, but it has already had more Update Constraints in Window passes than there are views in the window.` — app crashes when showing the recording overlay panel.

**Root cause:** `NSHostingView` uses Auto Layout internally and continuously recalculates constraints as SwiftUI state changes (bindings like `elapsedSeconds`, animations like the pulsing dot). When set directly as a borderless panel's `contentView`, the panel's fixed frame and the hosting view's dynamic intrinsic content size fight each other, creating an infinite constraint update loop.

**What didn't work:**
1. Setting `hostingView.frame` + `autoresizingMask` before assigning as contentView — same crash
2. Using `fittingSize` to match panel size to hosting view — still crashes because the hosting view's size changes dynamically with state updates

**Fix:** Wrap the `NSHostingView` in a plain `NSView` container. The wrapper has a fixed frame and serves as the panel's `contentView`. The hosting view is added as a subview with only centering constraints (no width/height constraints that would create cycles):
```swift
let wrapper = NSView(frame: NSRect(origin: .zero, size: panelSize))
hostingView.translatesAutoresizingMaskIntoConstraints = false
wrapper.addSubview(hostingView)
NSLayoutConstraint.activate([
    hostingView.centerXAnchor.constraint(equalTo: wrapper.centerXAnchor),
    hostingView.centerYAnchor.constraint(equalTo: wrapper.centerYAnchor),
])
panel.contentView = wrapper
```

**Lesson:** Never use `NSHostingView` directly as a borderless panel's `contentView` when the SwiftUI content has dynamic state or animations. The wrapper NSView breaks the constraint feedback loop by decoupling the panel's frame management from the hosting view's Auto Layout.
