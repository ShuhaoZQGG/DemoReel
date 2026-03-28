# 10. SCContentSharingPicker — Native Source Selection

**Problem:** Dropdown picker listing all windows was clunky and showed irrelevant items.

**Fix:** Use `SCContentSharingPicker` (macOS 14+) — the system-native picker that shows a transparent overlay. Users click a window or display to select it, same as QuickTime.

**Implementation notes:**
- Conform to `SCContentSharingPickerObserver`
- Call `picker.isActive = true` then `picker.present()`
- The delegate callback `contentSharingPicker(_:didUpdateWith:for:)` returns the `SCContentFilter`
- Must set `picker.isActive = false` after selection or cancellation
- The returned filter works directly with `SCStream`
