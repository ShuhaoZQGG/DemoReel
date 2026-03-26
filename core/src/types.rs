use serde::{Deserialize, Serialize};

#[derive(uniffi::Record, Clone, Debug, Serialize, Deserialize)]
pub struct MouseEvent {
    pub x: f64,
    pub y: f64,
    pub timestamp_ms: u64,
    pub click: bool,
}

#[derive(uniffi::Record, Clone, Debug, Serialize, Deserialize)]
pub struct ZoomKeyframe {
    pub start_ms: u64,
    pub end_ms: u64,
    pub center_x: f64,
    pub center_y: f64,
    pub scale: f64,
}

/// A single input event from the event log.
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum InputEvent {
    Move {
        x: f64,
        y: f64,
        ts: u64,
    },
    Click {
        x: f64,
        y: f64,
        ts: u64,
    },
    Scroll {
        x: f64,
        y: f64,
        ts: u64,
        delta_y: f64,
    },
}

impl InputEvent {
    pub fn x(&self) -> f64 {
        match self {
            InputEvent::Move { x, .. }
            | InputEvent::Click { x, .. }
            | InputEvent::Scroll { x, .. } => *x,
        }
    }

    pub fn y(&self) -> f64 {
        match self {
            InputEvent::Move { y, .. }
            | InputEvent::Click { y, .. }
            | InputEvent::Scroll { y, .. } => *y,
        }
    }

    pub fn timestamp_ms(&self) -> u64 {
        match self {
            InputEvent::Move { ts, .. }
            | InputEvent::Click { ts, .. }
            | InputEvent::Scroll { ts, .. } => *ts,
        }
    }

    pub fn is_click(&self) -> bool {
        matches!(self, InputEvent::Click { .. })
    }
}

/// Convert an InputEvent to the simpler MouseEvent used by the zoom engine.
impl From<&InputEvent> for MouseEvent {
    fn from(event: &InputEvent) -> Self {
        MouseEvent {
            x: event.x(),
            y: event.y(),
            timestamp_ms: event.timestamp_ms(),
            click: event.is_click(),
        }
    }
}

/// The full event log written alongside a recording.
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct EventLog {
    pub version: u32,
    pub recording_id: String,
    pub duration_ms: u64,
    pub screen_width: u32,
    pub screen_height: u32,
    pub events: Vec<InputEvent>,
}

/// UniFFI-compatible event record (enums with data can't cross FFI directly).
#[derive(uniffi::Record, Clone, Debug)]
pub struct InputEventRecord {
    pub event_type: String,
    pub x: f64,
    pub y: f64,
    pub timestamp_ms: u64,
    pub delta_y: f64,
}

/// UniFFI-compatible event log record.
#[derive(uniffi::Record, Clone, Debug)]
pub struct EventLogRecord {
    pub version: u32,
    pub recording_id: String,
    pub duration_ms: u64,
    pub screen_width: u32,
    pub screen_height: u32,
    pub events: Vec<InputEventRecord>,
}

impl From<&InputEvent> for InputEventRecord {
    fn from(event: &InputEvent) -> Self {
        match event {
            InputEvent::Move { x, y, ts } => InputEventRecord {
                event_type: "move".to_string(),
                x: *x,
                y: *y,
                timestamp_ms: *ts,
                delta_y: 0.0,
            },
            InputEvent::Click { x, y, ts } => InputEventRecord {
                event_type: "click".to_string(),
                x: *x,
                y: *y,
                timestamp_ms: *ts,
                delta_y: 0.0,
            },
            InputEvent::Scroll { x, y, ts, delta_y } => InputEventRecord {
                event_type: "scroll".to_string(),
                x: *x,
                y: *y,
                timestamp_ms: *ts,
                delta_y: *delta_y,
            },
        }
    }
}

impl From<&EventLog> for EventLogRecord {
    fn from(log: &EventLog) -> Self {
        EventLogRecord {
            version: log.version,
            recording_id: log.recording_id.clone(),
            duration_ms: log.duration_ms,
            screen_width: log.screen_width,
            screen_height: log.screen_height,
            events: log.events.iter().map(InputEventRecord::from).collect(),
        }
    }
}

impl EventLog {
    /// Convert all events to MouseEvents for the zoom engine.
    pub fn to_mouse_events(&self) -> Vec<MouseEvent> {
        self.events.iter().map(MouseEvent::from).collect()
    }
}

/// Configuration for the auto-zoom keyframe generator.
#[derive(uniffi::Record, Clone, Debug)]
pub struct ZoomConfig {
    pub scale: f64,
    pub ease_in_ms: u64,
    pub hold_ms: u64,
    pub ease_out_ms: u64,
    pub merge_threshold_ms: u64,
    pub enabled: bool,
}

impl Default for ZoomConfig {
    fn default() -> Self {
        ZoomConfig {
            scale: 2.0,
            ease_in_ms: 300,
            hold_ms: 600,
            ease_out_ms: 400,
            merge_threshold_ms: 300,
            enabled: true,
        }
    }
}

/// A smoothed cursor position with velocity information.
#[derive(uniffi::Record, Clone, Debug)]
pub struct SmoothedPoint {
    pub x: f64,
    pub y: f64,
    pub timestamp_ms: u64,
    pub velocity: f64,
}
