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
