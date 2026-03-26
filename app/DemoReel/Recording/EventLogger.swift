import AppKit
import Foundation

/// Captures mouse events via NSEvent global/local monitors during recording.
@Observable
final class EventLogger {
    private(set) var events: [RecordedEvent] = []
    private(set) var isLogging = false

    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var recordingStartTime: UInt64 = 0
    /// Window origin in Quartz screen coordinates (top-left origin)
    private var windowOriginQuartz: CGPoint = .zero
    /// Main screen height for converting AppKit→Quartz Y
    private var screenHeight: CGFloat = 0

    struct RecordedEvent: Codable {
        let type: String
        let x: Double
        let y: Double
        let ts: UInt64
        let delta_y: Double?

        enum CodingKeys: String, CodingKey {
            case type, x, y, ts
            case delta_y
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(type, forKey: .type)
            try container.encode(x, forKey: .x)
            try container.encode(y, forKey: .y)
            try container.encode(ts, forKey: .ts)
            if let dy = delta_y {
                try container.encode(dy, forKey: .delta_y)
            }
        }
    }

    /// Start capturing mouse events, converting to window-relative coordinates.
    /// - Parameters:
    ///   - windowQuartzOrigin: The window's top-left corner in Quartz screen coords
    ///     (from kCGWindowBounds, which uses top-left origin).
    ///   - screenHeight: Height of the main screen (for AppKit→Quartz Y conversion).
    func startLogging(windowQuartzOrigin: CGPoint = .zero, screenHeight: CGFloat = 0) {
        guard !isLogging else { return }

        self.windowOriginQuartz = windowQuartzOrigin
        self.screenHeight = screenHeight
        events = []
        recordingStartTime = mach_absolute_time()

        let mask: NSEvent.EventTypeMask = [
            .mouseMoved,
            .leftMouseDown,
            .rightMouseDown,
            .scrollWheel,
            .leftMouseDragged,
            .rightMouseDragged,
        ]

        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
            self?.handleNSEvent(event)
        }

        localMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            self?.handleNSEvent(event)
            return event
        }

        isLogging = true
    }

    /// Stop capturing events.
    func stopLogging() {
        guard isLogging else { return }

        if let monitor = globalMonitor {
            NSEvent.removeMonitor(monitor)
            globalMonitor = nil
        }
        if let monitor = localMonitor {
            NSEvent.removeMonitor(monitor)
            localMonitor = nil
        }
        isLogging = false
    }

    /// Save events to a JSON file matching the event log format.
    func save(
        to url: URL,
        recordingId: String,
        durationMs: UInt64,
        screenWidth: UInt32,
        screenHeight: UInt32
    ) throws {
        let log = EventLogFile(
            version: 1,
            recording_id: recordingId,
            duration_ms: durationMs,
            screen_width: screenWidth,
            screen_height: screenHeight,
            events: events
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(log)
        try data.write(to: url)
    }

    private func handleNSEvent(_ event: NSEvent) {
        // NSEvent.mouseLocation: AppKit screen coords (bottom-left origin)
        let mouseLocation = NSEvent.mouseLocation

        // Convert to Quartz screen coords (top-left origin)
        let quartzX = mouseLocation.x
        let quartzY = screenHeight - mouseLocation.y

        // Convert to window-relative coords (0,0 = window top-left)
        let x = quartzX - windowOriginQuartz.x
        let y = quartzY - windowOriginQuartz.y

        let timestampMs = elapsedMs()

        switch event.type {
        case .mouseMoved, .leftMouseDragged, .rightMouseDragged:
            events.append(RecordedEvent(
                type: "move", x: x, y: y, ts: timestampMs, delta_y: nil
            ))
        case .leftMouseDown, .rightMouseDown:
            events.append(RecordedEvent(
                type: "click", x: x, y: y, ts: timestampMs, delta_y: nil
            ))
        case .scrollWheel:
            events.append(RecordedEvent(
                type: "scroll", x: x, y: y, ts: timestampMs,
                delta_y: Double(event.scrollingDeltaY)
            ))
        default:
            break
        }
    }

    private func elapsedMs() -> UInt64 {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        let elapsed = mach_absolute_time() - recordingStartTime
        let nanos = elapsed * UInt64(info.numer) / UInt64(info.denom)
        return nanos / 1_000_000
    }
}

/// JSON file structure matching the event log format.
private struct EventLogFile: Codable {
    let version: UInt32
    let recording_id: String
    let duration_ms: UInt64
    let screen_width: UInt32
    let screen_height: UInt32
    let events: [EventLogger.RecordedEvent]
}
