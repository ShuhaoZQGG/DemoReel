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

/// Background configuration for the video canvas.
///
/// Uses a type string + fields pattern for FFI compatibility.
/// `bg_type`: "solid", "gradient", or "transparent"
#[derive(uniffi::Record, Clone, Debug)]
pub struct BackgroundConfig {
    pub bg_type: String,
    pub hex: String,
    pub gradient_from_hex: String,
    pub gradient_to_hex: String,
    pub gradient_angle_degrees: f64,
}

impl Default for BackgroundConfig {
    fn default() -> Self {
        BackgroundConfig {
            bg_type: "solid".to_string(),
            hex: "#1a1a2e".to_string(),
            gradient_from_hex: "#667eea".to_string(),
            gradient_to_hex: "#764ba2".to_string(),
            gradient_angle_degrees: 135.0,
        }
    }
}

/// Aspect ratio for the output video.
///
/// Values: "landscape_16x9", "square_1x1", "portrait_9x16", "auto"
#[derive(uniffi::Record, Clone, Debug)]
pub struct AspectRatioConfig {
    pub ratio: String,
}

impl Default for AspectRatioConfig {
    fn default() -> Self {
        AspectRatioConfig {
            ratio: "landscape_16x9".to_string(),
        }
    }
}

impl AspectRatioConfig {
    pub fn aspect_value(&self) -> Option<f64> {
        match self.ratio.as_str() {
            "landscape_16x9" => Some(16.0 / 9.0),
            "square_1x1" => Some(1.0),
            "portrait_9x16" => Some(9.0 / 16.0),
            "landscape_4x3" => Some(4.0 / 3.0),
            _ => None, // "auto" — use source aspect
        }
    }
}

/// Full style configuration for the video output.
#[derive(uniffi::Record, Clone, Debug)]
pub struct StyleConfig {
    pub background: BackgroundConfig,
    pub padding: f64,
    pub corner_radius: f64,
    pub shadow_enabled: bool,
    pub shadow_intensity: f64,
    pub aspect_ratio: AspectRatioConfig,
}

impl Default for StyleConfig {
    fn default() -> Self {
        StyleConfig {
            background: BackgroundConfig::default(),
            padding: 32.0,
            corner_radius: 12.0,
            shadow_enabled: true,
            shadow_intensity: 0.5,
            aspect_ratio: AspectRatioConfig::default(),
        }
    }
}

/// Cursor rendering configuration.
///
/// `cursor_style`: "system", "circle", or "hidden"
#[derive(uniffi::Record, Clone, Debug)]
pub struct CursorConfig {
    pub cursor_style: String,
    pub size_multiplier: f64,
    pub click_highlight: bool,
    pub highlight_color_hex: String,
}

impl Default for CursorConfig {
    fn default() -> Self {
        CursorConfig {
            cursor_style: "system".to_string(),
            size_multiplier: 1.0,
            click_highlight: true,
            highlight_color_hex: "#3b82f6".to_string(),
        }
    }
}

/// Output format for export.
///
/// Values: "mp4", "gif", "webm"
#[derive(uniffi::Record, Clone, Debug)]
pub struct OutputFormatConfig {
    pub format: String,
}

impl Default for OutputFormatConfig {
    fn default() -> Self {
        OutputFormatConfig {
            format: "mp4".to_string(),
        }
    }
}

/// Full export configuration.
#[derive(uniffi::Record, Clone, Debug)]
pub struct ExportConfig {
    pub input_video_path: String,
    pub events_json_path: String,
    pub output_path: String,
    pub zoom_config: ZoomConfig,
    pub style_config: StyleConfig,
    pub cursor_config: CursorConfig,
    pub output_width: u32,
    pub output_height: u32,
    pub fps: u32,
    pub format: OutputFormatConfig,
}

/// Export error type.
#[derive(uniffi::Error, thiserror::Error, Debug)]
pub enum ExportError {
    #[error("FFmpeg not found: {message}")]
    FfmpegNotFound { message: String },
    #[error("FFmpeg failed: {message}")]
    FfmpegFailed { message: String },
    #[error("IO error: {message}")]
    IoError { message: String },
    #[error("Invalid config: {message}")]
    InvalidConfig { message: String },
}

impl From<std::io::Error> for ExportError {
    fn from(err: std::io::Error) -> Self {
        ExportError::IoError {
            message: err.to_string(),
        }
    }
}

/// Export progress info passed via callback.
#[derive(uniffi::Record, Clone, Debug)]
pub struct ExportProgress {
    pub percent: f64,
    pub stage: String,
}

/// .demoreel project file format.
///
/// JSON manifest that stores references to the recording files and all
/// user-configured settings (zoom, style, cursor).
#[derive(uniffi::Record, Clone, Debug, Serialize, Deserialize)]
pub struct ProjectFile {
    pub version: u32,
    pub name: String,
    pub created_at: String,
    pub video_path: String,
    pub events_path: String,
    pub zoom_scale: f64,
    pub zoom_ease_in_ms: u64,
    pub zoom_hold_ms: u64,
    pub zoom_ease_out_ms: u64,
    pub zoom_merge_threshold_ms: u64,
    pub zoom_enabled: bool,
    pub bg_type: String,
    pub bg_hex: String,
    pub bg_gradient_from_hex: String,
    pub bg_gradient_to_hex: String,
    pub bg_gradient_angle: f64,
    pub padding: f64,
    pub corner_radius: f64,
    pub shadow_enabled: bool,
    pub shadow_intensity: f64,
    pub aspect_ratio: String,
    pub cursor_style: String,
    pub cursor_size_multiplier: f64,
    pub cursor_click_highlight: bool,
    pub cursor_highlight_color_hex: String,
    pub trim_start_ms: u64,
    pub trim_end_ms: u64,
}

/// Error type for event log parsing.
#[derive(uniffi::Error, thiserror::Error, Debug)]
pub enum ParseError {
    #[error("Invalid JSON: {message}")]
    InvalidJson { message: String },
}

/// Error type for project file operations.
#[derive(uniffi::Error, thiserror::Error, Debug)]
pub enum ProjectError {
    #[error("IO error: {message}")]
    IoError { message: String },
    #[error("Parse error: {message}")]
    ParseError { message: String },
    #[error("Invalid project: {message}")]
    InvalidProject { message: String },
}

impl From<std::io::Error> for ProjectError {
    fn from(err: std::io::Error) -> Self {
        ProjectError::IoError {
            message: err.to_string(),
        }
    }
}

impl From<serde_json::Error> for ProjectError {
    fn from(err: serde_json::Error) -> Self {
        ProjectError::ParseError {
            message: err.to_string(),
        }
    }
}
