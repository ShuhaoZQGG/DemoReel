import CoreGraphics
import Foundation

/// Captures mouse events via CGEventTap during recording.
@Observable
final class EventLogger {
    private(set) var events: [RecordedEvent] = []
    private(set) var isLogging = false

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var recordingStartTime: UInt64 = 0

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

    /// Start capturing mouse events.
    func startLogging() {
        guard !isLogging else { return }

        events = []
        recordingStartTime = mach_absolute_time()

        let eventMask: CGEventMask = (
            (1 << CGEventType.mouseMoved.rawValue) |
            (1 << CGEventType.leftMouseDown.rawValue) |
            (1 << CGEventType.rightMouseDown.rawValue) |
            (1 << CGEventType.scrollWheel.rawValue) |
            (1 << CGEventType.leftMouseDragged.rawValue) |
            (1 << CGEventType.rightMouseDragged.rawValue)
        )

        let callback: CGEventTapCallBack = { _, type, event, userInfo in
            guard let userInfo = userInfo else { return Unmanaged.passRetained(event) }
            let logger = Unmanaged<EventLogger>.fromOpaque(userInfo).takeUnretainedValue()
            logger.handleEvent(type: type, event: event)
            return Unmanaged.passRetained(event)
        }

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: eventMask,
            callback: callback,
            userInfo: selfPtr
        ) else {
            return
        }

        eventTap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        isLogging = true
    }

    /// Stop capturing events.
    func stopLogging() {
        guard isLogging else { return }

        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
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

    private func handleEvent(type: CGEventType, event: CGEvent) {
        let location = event.location
        let timestampMs = elapsedMs()

        switch type {
        case .mouseMoved, .leftMouseDragged, .rightMouseDragged:
            events.append(RecordedEvent(
                type: "move",
                x: location.x,
                y: location.y,
                ts: timestampMs,
                delta_y: nil
            ))
        case .leftMouseDown, .rightMouseDown:
            events.append(RecordedEvent(
                type: "click",
                x: location.x,
                y: location.y,
                ts: timestampMs,
                delta_y: nil
            ))
        case .scrollWheel:
            let deltaY = event.getDoubleValueField(.scrollWheelEventDeltaAxis1)
            events.append(RecordedEvent(
                type: "scroll",
                x: location.x,
                y: location.y,
                ts: timestampMs,
                delta_y: deltaY
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
