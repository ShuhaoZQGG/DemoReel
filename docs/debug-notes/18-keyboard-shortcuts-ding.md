# 18. Keyboard Shortcuts — "Ding" Sound, Keys Ignored

**Problem:** Pressing `C` (scissor mode) or `Z` (add zoom) played the macOS "ding" sound and did nothing. Space bar (play/pause) worked fine.

**Root cause:** `C` and `Z` used SwiftUI's `.onKeyPress()` modifier on `TimelineView`, which requires the view to have keyboard focus. Space bar worked because it used `.keyboardShortcut(.space, modifiers: [])` on a Button — this goes through the command/menu system, which is focus-independent. When the user clicked sidebar controls (sliders, pickers), focus moved away from `TimelineView`, and `.onKeyPress` stopped receiving events. Unhandled key events → macOS plays the system "ding".

**What didn't work:**
1. **Forced focus management:** `@FocusState` + `.focused($isFocused)` + `.onAppear { isFocused = true }` — focus still gets stolen by sidebar interactions.
2. **Passing `KeyboardShortcutMonitor` to `TimelineView` and registering handlers in `.onAppear`:** Failed for two reasons:
   - **Timing:** The monitor was created in `.task` (async), but `.onAppear` fired first when `keyMonitor` was still `nil`.
   - **Value semantics:** `[self]` capture in SwiftUI View closures captures a frozen struct copy — `@State` mutations in the captured closure have no effect on the actual view state.

**Fix:** `NSEvent.addLocalMonitorForEvents(matching: .keyDown)` — intercepts key events at the application level regardless of focus. This is the standard pattern for pro video editors.

**Implementation (three iterations to get right):**

1. **`KeyboardShortcutMonitor`** — An `@Observable` class that installs a local NSEvent monitor. Instead of closure-based handlers (which suffer from value-capture issues), it publishes an `ActionEvent` with a unique UUID per event. `EditorView` observes changes via `.onChange(of: keyMonitor.lastAction)` and handles actions in its own context where `@State` mutations work correctly.

2. **Modifier filtering:** Only intercepts bare keystrokes (no Cmd/Option/Ctrl/Shift held) so Cmd+Z (undo), Cmd+C (copy) etc. still work. Also skips interception when a sheet is presented.

3. **Special keys by keyCode:** Delete (keyCode 51), Forward Delete (117), and Escape (53) can't be matched by character — matched by `event.keyCode` instead.

4. **State hoisting:** `scissorModeActive` and `selection` (for delete) were moved from `TimelineView` `@State` to `EditorView` `@State`, passed down as `@Binding`. This lets `EditorView` handle all shortcut actions with proper state access.

**Lesson:** SwiftUI's `.onKeyPress()` is unreliable for app-wide shortcuts because it depends on focus, which is easily lost. For editor-style apps where shortcuts must work regardless of which panel has focus, use `NSEvent.addLocalMonitorForEvents`. Don't try to register closures that capture SwiftUI View struct state — use `@Observable` + `.onChange` instead to stay in SwiftUI's reactive system.
