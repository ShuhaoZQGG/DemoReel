import ScreenCaptureKit
import AppKit

/// Bridges SCContentSharingPicker to SwiftUI by observing picker events.
@Observable
final class SourcePickerCoordinator: NSObject, SCContentSharingPickerObserver {
    /// The content filter returned by the picker when the user makes a selection.
    var selectedFilter: SCContentFilter?
    /// Set to true when the user cancels the picker.
    var didCancel = false

    private var isActive = false

    override init() {
        super.init()
        SCContentSharingPicker.shared.add(self)
    }

    deinit {
        SCContentSharingPicker.shared.remove(self)
    }

    /// Present the system content picker overlay.
    func present(for stream: SCStream? = nil) {
        let picker = SCContentSharingPicker.shared
        picker.isActive = true

        selectedFilter = nil
        didCancel = false
        isActive = true

        // Configure what the picker allows
        var config = SCContentSharingPickerConfiguration()
        config.allowedPickerModes = [.singleWindow, .singleDisplay]
        picker.defaultConfiguration = config

        if let stream {
            picker.present(for: stream)
        } else {
            picker.present()
        }
    }

    // MARK: - SCContentSharingPickerObserver

    func contentSharingPicker(_ picker: SCContentSharingPicker, didUpdateWith filter: SCContentFilter, for stream: SCStream?) {
        selectedFilter = filter
        isActive = false
        picker.isActive = false
        // Re-show the app
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    func contentSharingPicker(_ picker: SCContentSharingPicker, didCancelFor stream: SCStream?) {
        didCancel = true
        isActive = false
        picker.isActive = false
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    func contentSharingPickerStartDidFailWithError(_ error: Error) {
        didCancel = true
        isActive = false
        SCContentSharingPicker.shared.isActive = false
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
}
