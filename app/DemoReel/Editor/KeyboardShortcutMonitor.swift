import AppKit

/// Intercepts bare-key shortcuts (no modifiers) at the app level via NSEvent local monitor.
/// This ensures shortcuts like C and Z work regardless of which SwiftUI view has focus.
@Observable
final class KeyboardShortcutMonitor {
    /// Published action that SwiftUI views can observe via .onChange.
    /// Wraps each action with a unique ID so repeated identical actions still trigger onChange.
    var lastAction: ActionEvent?

    struct ActionEvent: Equatable {
        let action: EditorAction
        private let id = UUID()

        static func == (lhs: ActionEvent, rhs: ActionEvent) -> Bool {
            lhs.id == rhs.id
        }
    }

    enum EditorAction {
        case toggleScissor
        case addZoom
        case deleteSelection
        case deactivateScissor
    }

    private var monitor: Any?

    private static let charActions: [Character: EditorAction] = [
        "c": .toggleScissor,
        "z": .addZoom,
    ]

    private static let keyCodeActions: [UInt16: EditorAction] = [
        51: .deleteSelection,   // Backspace/Delete
        117: .deleteSelection,  // Forward Delete
        53: .deactivateScissor, // Escape
    ]

    init() {
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }

            // Don't intercept when a sheet is presented (e.g. export dialog)
            if let window = NSApp.keyWindow, !window.sheets.isEmpty {
                return event
            }

            // Only handle bare keystrokes — ignore Cmd, Option, Control, Shift
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard flags.isEmpty || flags == .function else { return event }

            // Check keyCode actions first (for special keys like Delete, Escape)
            if let action = Self.keyCodeActions[event.keyCode] {
                self.lastAction = ActionEvent(action: action)
                return nil
            }

            // Then check character actions (for letter keys like C, Z)
            if let chars = event.charactersIgnoringModifiers,
               let char = chars.first,
               let action = Self.charActions[char] {
                self.lastAction = ActionEvent(action: action)
                return nil
            }

            return event
        }
    }

    deinit {
        if let monitor { NSEvent.removeMonitor(monitor) }
    }
}
