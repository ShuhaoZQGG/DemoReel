# 11. Floating Recording Controls

**Implementation:** `NSPanel` subclass with:
- `.borderless` + `.nonactivatingPanel` style masks — no title bar, doesn't steal focus
- `.floating` level — stays above all windows
- `isMovableByWindowBackground = true` — draggable
- `hidesOnDeactivate = false` — stays visible when app is in background
- Hosts a SwiftUI view via `NSHostingView`

**Key:** `.nonactivatingPanel` is critical — without it, clicking the stop button would activate DemoReel and steal focus from the recorded window.
