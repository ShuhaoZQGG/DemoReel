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
        case undo
        case redo
        case nudgeFocusPoint(dx: Double, dy: Double)
        case adjustZoomDuration(deltaMs: Int64)
        case adjustZoomScale(delta: Double)
        case nudgeZoomPosition(deltaMs: Int64)
        case duplicateSelection
        case selectNextZoom
        case selectPreviousZoom
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

            // Handle undo/redo shortcuts before bare-key guard
            // Undo: Cmd+Z, Cmd+Shift+Z
            // Redo: Cmd+Y, Cmd+Shift+Y
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if let chars = event.charactersIgnoringModifiers {
                if chars == "z" && (flags == .command || flags == [.command, .shift]) {
                    self.lastAction = ActionEvent(action: .undo)
                    return nil
                }
                if chars == "y" && (flags == .command || flags == [.command, .shift]) {
                    self.lastAction = ActionEvent(action: .redo)
                    return nil
                }
                if chars == "d" && flags == .command {
                    self.lastAction = ActionEvent(action: .duplicateSelection)
                    return nil
                }
            }

            // Only handle bare keystrokes (plus arrow-key modifiers and Shift for nudge)
            let bareOrArrow = flags.isEmpty
                || flags == .function
                || flags == [.function, .numericPad]
                || flags == [.function, .numericPad, .shift]
                || flags == .shift
            guard bareOrArrow else { return event }

            // Arrow keys for focus point nudge (before other keyCode actions)
            let arrowDirections: [UInt16: (Double, Double)] = [
                123: (-1, 0),  // left
                124: (1, 0),   // right
                125: (0, 1),   // down
                126: (0, -1),  // up
            ]
            if let direction = arrowDirections[event.keyCode] {
                let step: Double = flags.contains(.shift) ? 1.0 : 10.0
                self.lastAction = ActionEvent(action: .nudgeFocusPoint(
                    dx: direction.0 * step, dy: direction.1 * step
                ))
                return nil
            }

            // Tab for zoom clip navigation
            if event.keyCode == 48 {
                self.lastAction = ActionEvent(action: flags.contains(.shift) ? .selectPreviousZoom : .selectNextZoom)
                return nil
            }

            // Check keyCode actions first (for special keys like Delete, Escape)
            if let action = Self.keyCodeActions[event.keyCode] {
                self.lastAction = ActionEvent(action: action)
                return nil
            }

            // Zoom clip adjustment keys (Shift changes step size)
            if let chars = event.charactersIgnoringModifiers, let char = chars.first {
                let isShift = flags.contains(.shift)
                switch char {
                case "[":
                    self.lastAction = ActionEvent(action: .adjustZoomDuration(deltaMs: isShift ? -50 : -200))
                    return nil
                case "]":
                    self.lastAction = ActionEvent(action: .adjustZoomDuration(deltaMs: isShift ? 50 : 200))
                    return nil
                case "=":
                    self.lastAction = ActionEvent(action: .adjustZoomScale(delta: 0.25))
                    return nil
                case "-":
                    self.lastAction = ActionEvent(action: .adjustZoomScale(delta: -0.25))
                    return nil
                case ",":
                    self.lastAction = ActionEvent(action: .nudgeZoomPosition(deltaMs: isShift ? -25 : -100))
                    return nil
                case ".":
                    self.lastAction = ActionEvent(action: .nudgeZoomPosition(deltaMs: isShift ? 25 : 100))
                    return nil
                default:
                    break
                }
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
