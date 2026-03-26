pub mod compositor;
pub mod cursor;
pub mod export;
pub mod project;
pub mod types;
pub mod zoom;

use types::{MouseEvent, ZoomKeyframe};

uniffi::setup_scaffolding!();

/// Returns the core library version string.
#[uniffi::export]
pub fn core_version() -> String {
    env!("CARGO_PKG_VERSION").to_string()
}

/// Generate zoom keyframes from mouse events.
///
/// Analyzes click events and produces keyframes for zoom animations.
#[uniffi::export]
pub fn generate_zoom_keyframes(events: Vec<MouseEvent>) -> Vec<ZoomKeyframe> {
    zoom::generate_zoom_keyframes(&events)
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
}
