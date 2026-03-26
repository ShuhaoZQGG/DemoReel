use crate::types::{MouseEvent, ZoomKeyframe};

/// Generate zoom keyframes from mouse events.
///
/// Filters for click events and produces a zoom keyframe centered on each click.
/// This is the M0 placeholder algorithm — M2 will add click clustering,
/// overlap merging, and configurable easing.
pub fn generate_zoom_keyframes(events: &[MouseEvent]) -> Vec<ZoomKeyframe> {
    events
        .iter()
        .filter(|e| e.click)
        .map(|e| ZoomKeyframe {
            start_ms: e.timestamp_ms.saturating_sub(200),
            end_ms: e.timestamp_ms + 800,
            center_x: e.x,
            center_y: e.y,
            scale: 2.0,
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn empty_events_returns_empty_keyframes() {
        let result = generate_zoom_keyframes(&[]);
        assert!(result.is_empty());
    }

    #[test]
    fn click_generates_keyframe() {
        let events = vec![MouseEvent {
            x: 100.0,
            y: 200.0,
            timestamp_ms: 1000,
            click: true,
        }];
        let keyframes = generate_zoom_keyframes(&events);
        assert_eq!(keyframes.len(), 1);
        assert_eq!(keyframes[0].center_x, 100.0);
        assert_eq!(keyframes[0].center_y, 200.0);
        assert_eq!(keyframes[0].start_ms, 800);
        assert_eq!(keyframes[0].end_ms, 1800);
        assert_eq!(keyframes[0].scale, 2.0);
    }

    #[test]
    fn non_click_events_ignored() {
        let events = vec![
            MouseEvent {
                x: 50.0,
                y: 50.0,
                timestamp_ms: 100,
                click: false,
            },
            MouseEvent {
                x: 150.0,
                y: 150.0,
                timestamp_ms: 200,
                click: false,
            },
        ];
        let keyframes = generate_zoom_keyframes(&events);
        assert!(keyframes.is_empty());
    }

    #[test]
    fn multiple_clicks_produce_multiple_keyframes() {
        let events = vec![
            MouseEvent {
                x: 10.0,
                y: 20.0,
                timestamp_ms: 500,
                click: true,
            },
            MouseEvent {
                x: 100.0,
                y: 100.0,
                timestamp_ms: 1000,
                click: false,
            },
            MouseEvent {
                x: 30.0,
                y: 40.0,
                timestamp_ms: 2000,
                click: true,
            },
            MouseEvent {
                x: 50.0,
                y: 60.0,
                timestamp_ms: 3000,
                click: true,
            },
        ];
        let keyframes = generate_zoom_keyframes(&events);
        assert_eq!(keyframes.len(), 3);
        assert_eq!(keyframes[0].center_x, 10.0);
        assert_eq!(keyframes[1].center_x, 30.0);
        assert_eq!(keyframes[2].center_x, 50.0);
    }

    #[test]
    fn early_click_saturates_start_ms() {
        let events = vec![MouseEvent {
            x: 0.0,
            y: 0.0,
            timestamp_ms: 100,
            click: true,
        }];
        let keyframes = generate_zoom_keyframes(&events);
        assert_eq!(keyframes[0].start_ms, 0);
    }
}
