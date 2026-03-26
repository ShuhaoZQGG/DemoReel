pub mod compositor;
pub mod cursor;
pub mod export;
pub mod project;
pub mod types;
pub mod zoom;

use types::{EventLog, EventLogRecord, MouseEvent, SmoothedPoint, ZoomConfig, ZoomKeyframe};

uniffi::setup_scaffolding!();

/// Returns the core library version string.
#[uniffi::export]
pub fn core_version() -> String {
    env!("CARGO_PKG_VERSION").to_string()
}

/// Generate zoom keyframes from mouse events using default settings.
#[uniffi::export]
pub fn generate_zoom_keyframes(events: Vec<MouseEvent>) -> Vec<ZoomKeyframe> {
    zoom::generate_zoom_keyframes(&events)
}

/// Generate zoom keyframes from mouse events with custom configuration.
#[uniffi::export]
pub fn generate_zoom_keyframes_with_config(
    events: Vec<MouseEvent>,
    config: ZoomConfig,
) -> Vec<ZoomKeyframe> {
    zoom::generate_zoom_keyframes_with_config(&events, &config)
}

/// Get the interpolated zoom scale at a given timestamp.
///
/// Returns 1.0 when outside any keyframe.
#[uniffi::export]
pub fn zoom_scale_at(keyframes: Vec<ZoomKeyframe>, timestamp_ms: u64, config: ZoomConfig) -> f64 {
    zoom::zoom_scale_at(&keyframes, timestamp_ms, &config)
}

/// Smooth a raw cursor path using exponential moving average.
///
/// `alpha` controls smoothing: 0.0 = very smooth, 1.0 = no smoothing.
/// Recommended default: 0.3.
#[uniffi::export]
pub fn smooth_cursor_path(positions: Vec<MouseEvent>, alpha: f64) -> Vec<SmoothedPoint> {
    cursor::smooth_cursor_path(&positions, alpha)
}

/// Parse an event log JSON string into a structured record.
#[uniffi::export]
pub fn parse_event_log(json: String) -> Result<EventLogRecord, String> {
    let log: EventLog = serde_json::from_str(&json).map_err(|e| e.to_string())?;
    Ok(EventLogRecord::from(&log))
}

/// Parse an event log and extract MouseEvents for the zoom engine.
#[uniffi::export]
pub fn mouse_events_from_log(json: String) -> Result<Vec<MouseEvent>, String> {
    let log: EventLog = serde_json::from_str(&json).map_err(|e| e.to_string())?;
    Ok(log.to_mouse_events())
}

/// Return the default zoom configuration.
#[uniffi::export]
pub fn default_zoom_config() -> ZoomConfig {
    ZoomConfig::default()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn core_version_is_not_empty() {
        assert!(!core_version().is_empty());
    }

    #[test]
    fn core_version_matches_cargo() {
        assert_eq!(core_version(), "0.1.0");
    }

    #[test]
    fn parse_event_log_roundtrip() {
        let json = r#"{
            "version": 1,
            "recording_id": "test-uuid",
            "duration_ms": 5000,
            "screen_width": 1920,
            "screen_height": 1080,
            "events": [
                {"type": "move", "x": 100.0, "y": 200.0, "ts": 0},
                {"type": "click", "x": 500.0, "y": 300.0, "ts": 1200},
                {"type": "scroll", "x": 500.0, "y": 300.0, "ts": 2400, "delta_y": -3.0}
            ]
        }"#;

        let record = parse_event_log(json.to_string()).unwrap();
        assert_eq!(record.version, 1);
        assert_eq!(record.recording_id, "test-uuid");
        assert_eq!(record.events.len(), 3);
        assert_eq!(record.events[0].event_type, "move");
        assert_eq!(record.events[1].event_type, "click");
        assert_eq!(record.events[1].x, 500.0);
        assert_eq!(record.events[2].event_type, "scroll");
        assert_eq!(record.events[2].delta_y, -3.0);
    }

    #[test]
    fn mouse_events_from_log_converts_all() {
        let json = r#"{
            "version": 1,
            "recording_id": "test",
            "duration_ms": 3000,
            "screen_width": 1920,
            "screen_height": 1080,
            "events": [
                {"type": "move", "x": 50.0, "y": 50.0, "ts": 0},
                {"type": "click", "x": 100.0, "y": 200.0, "ts": 1000},
                {"type": "move", "x": 150.0, "y": 150.0, "ts": 1500}
            ]
        }"#;

        let mouse_events = mouse_events_from_log(json.to_string()).unwrap();
        assert_eq!(mouse_events.len(), 3);
        assert!(!mouse_events[0].click);
        assert!(mouse_events[1].click);
        assert!(!mouse_events[2].click);
    }

    #[test]
    fn parse_event_log_invalid_json() {
        let result = parse_event_log("not json".to_string());
        assert!(result.is_err());
    }

    #[test]
    fn end_to_end_log_to_keyframes() {
        let json = r#"{
            "version": 1,
            "recording_id": "e2e-test",
            "duration_ms": 10000,
            "screen_width": 2560,
            "screen_height": 1440,
            "events": [
                {"type": "move", "x": 100.0, "y": 100.0, "ts": 0},
                {"type": "click", "x": 500.0, "y": 300.0, "ts": 1200},
                {"type": "move", "x": 600.0, "y": 400.0, "ts": 4000},
                {"type": "click", "x": 800.0, "y": 600.0, "ts": 6000}
            ]
        }"#;

        let mouse_events = mouse_events_from_log(json.to_string()).unwrap();
        let keyframes = generate_zoom_keyframes(mouse_events);
        assert_eq!(keyframes.len(), 2);
        assert_eq!(keyframes[0].center_x, 500.0);
        assert_eq!(keyframes[1].center_x, 800.0);
    }

    #[test]
    fn end_to_end_log_to_smoothed_cursor() {
        let json = r#"{
            "version": 1,
            "recording_id": "cursor-test",
            "duration_ms": 200,
            "screen_width": 1920,
            "screen_height": 1080,
            "events": [
                {"type": "move", "x": 0.0, "y": 0.0, "ts": 0},
                {"type": "move", "x": 100.0, "y": 0.0, "ts": 50},
                {"type": "move", "x": 80.0, "y": 0.0, "ts": 100},
                {"type": "move", "x": 110.0, "y": 0.0, "ts": 150}
            ]
        }"#;

        let mouse_events = mouse_events_from_log(json.to_string()).unwrap();
        let smoothed = smooth_cursor_path(mouse_events, 0.3);
        assert_eq!(smoothed.len(), 4);
        // Smoothed path should trend toward 100 but with less jitter
        assert!(smoothed[3].x > 0.0);
        assert!(smoothed[3].x < 110.0);
    }
}
