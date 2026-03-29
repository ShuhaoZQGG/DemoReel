# Recording Module

Screen capture, event logging, and recording UI.

## Files

- `ScreenRecorder.swift` — ScreenCaptureKit wrapper; writes H.264 .mov via AVAssetWriter
- `EventLogger.swift` — Mouse/keyboard capture via NSEvent monitors; saves JSON with window-relative coords
- `AudioCapture.swift` — Thin holder for AVAssetWriterInput; audio buffers fed externally from SCStream
- `RecordingView.swift` — Main recording UI; orchestrates recorder, logger, audio, and overlay panel
- `RecordingOverlayView.swift` — Floating timer/pause/finish SwiftUI controls
- `RecordingOverlayPanel.swift` — NSPanel subclass; always-on-top, non-activating, joins all spaces
- `SourcePickerCoordinator.swift` — Bridges SCContentSharingPicker to SwiftUI via observer pattern

## Gotchas

- Three coordinate systems in play: AppKit (bottom-left), Quartz (top-left), window-relative
- RecordingView wraps NSHostingView in plain NSView to avoid Auto Layout constraint cycles
- ScreenRecorder doubles resolution (2x) for retina output
- EventLogger uses mach_absolute_time() for nanosecond precision; subtracts paused duration
- RecordingOverlayPanel uses .nonActivatingPanel to avoid stealing focus from recorded app
