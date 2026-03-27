import AppKit
import SwiftUI

/// A borderless, always-on-top floating panel for recording controls.
/// Doesn't steal focus from the app being recorded.
final class RecordingOverlayPanel: NSPanel {
    init(size: CGSize) {
        super.init(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        isReleasedWhenClosed = false
        isOpaque = false
        backgroundColor = .clear
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isMovableByWindowBackground = true
        hidesOnDeactivate = false

        // Position at top-center of the main screen
        if let screen = NSScreen.main {
            let screenFrame = screen.visibleFrame
            let x = screenFrame.midX - size.width / 2
            let y = screenFrame.maxY - size.height - 12
            setFrameOrigin(NSPoint(x: x, y: y))
        }
    }
}
