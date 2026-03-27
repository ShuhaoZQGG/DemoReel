use crate::types::{MouseEvent, SmoothedPoint};

/// Smooth a raw cursor path using exponential moving average.
///
/// `alpha` controls responsiveness: higher (closer to 1.0) = more responsive,
/// lower (closer to 0.0) = smoother. Default recommended: 0.3.
pub fn smooth_cursor_path(positions: &[MouseEvent], alpha: f64) -> Vec<SmoothedPoint> {
    let alpha = alpha.clamp(0.01, 1.0);

    if positions.is_empty() {
        return Vec::new();
    }

    let mut result = Vec::with_capacity(positions.len());

    let first = &positions[0];
    result.push(SmoothedPoint {
        x: first.x,
        y: first.y,
        timestamp_ms: first.timestamp_ms,
        velocity: 0.0,
    });

    for i in 1..positions.len() {
        let prev_smoothed = &result[i - 1];
        let raw = &positions[i];
        let smoothed_x = alpha * raw.x + (1.0 - alpha) * prev_smoothed.x;
        let smoothed_y = alpha * raw.y + (1.0 - alpha) * prev_smoothed.y;

        let dt_ms = raw.timestamp_ms.saturating_sub(prev_smoothed.timestamp_ms);
        let velocity = if dt_ms > 0 {
            let dx = smoothed_x - prev_smoothed.x;
            let dy = smoothed_y - prev_smoothed.y;
            let distance = (dx * dx + dy * dy).sqrt();
            distance / (dt_ms as f64 / 1000.0)
        } else {
            0.0
        };

        result.push(SmoothedPoint {
            x: smoothed_x,
            y: smoothed_y,
            timestamp_ms: raw.timestamp_ms,
            velocity,
        });
    }

    result
}

#[cfg(test)]
mod tests {
    use super::*;

    fn pos(x: f64, y: f64, ts: u64) -> MouseEvent {
        MouseEvent {
            x,
            y,
            timestamp_ms: ts,
            click: false,
        }
    }

    #[test]
    fn empty_input_returns_empty() {
        let result = smooth_cursor_path(&[], 0.3);
        assert!(result.is_empty());
    }

    #[test]
    fn single_point_returns_same() {
        let result = smooth_cursor_path(&[pos(100.0, 200.0, 0)], 0.3);
        assert_eq!(result.len(), 1);
        assert_eq!(result[0].x, 100.0);
        assert_eq!(result[0].y, 200.0);
        assert_eq!(result[0].velocity, 0.0);
    }

    #[test]
    fn smoothing_reduces_jitter() {
        // Jittery path that should be smoothed
        let positions = vec![
            pos(100.0, 100.0, 0),
            pos(110.0, 100.0, 16),
            pos(95.0, 100.0, 32),  // jitter back
            pos(108.0, 100.0, 48),
            pos(97.0, 100.0, 64),  // jitter back
        ];
        let smoothed = smooth_cursor_path(&positions, 0.3);
        assert_eq!(smoothed.len(), 5);

        // Smoothed values should have less variance than raw
        let raw_range = 110.0 - 95.0; // 15.0
        let smoothed_xs: Vec<f64> = smoothed.iter().map(|p| p.x).collect();
        let smoothed_min = smoothed_xs.iter().cloned().fold(f64::INFINITY, f64::min);
        let smoothed_max = smoothed_xs.iter().cloned().fold(f64::NEG_INFINITY, f64::max);
        let smoothed_range = smoothed_max - smoothed_min;
        assert!(smoothed_range < raw_range);
    }

    #[test]
    fn alpha_one_passes_through() {
        let positions = vec![
            pos(100.0, 200.0, 0),
            pos(200.0, 300.0, 100),
        ];
        let smoothed = smooth_cursor_path(&positions, 1.0);
        assert_eq!(smoothed[1].x, 200.0);
        assert_eq!(smoothed[1].y, 300.0);
    }

    #[test]
    fn velocity_is_computed() {
        let positions = vec![
            pos(0.0, 0.0, 0),
            pos(100.0, 0.0, 1000), // 100px in 1s = 100px/s with alpha=1.0
        ];
        let smoothed = smooth_cursor_path(&positions, 1.0);
        assert!((smoothed[1].velocity - 100.0).abs() < 0.01);
    }

    #[test]
    fn low_alpha_smooths_more() {
        let positions = vec![
            pos(0.0, 0.0, 0),
            pos(100.0, 0.0, 100),
        ];
        let low = smooth_cursor_path(&positions, 0.1);
        let high = smooth_cursor_path(&positions, 0.9);
        // Low alpha should result in position closer to origin
        assert!(low[1].x < high[1].x);
    }

    #[test]
    fn timestamps_are_preserved() {
        let positions = vec![
            pos(0.0, 0.0, 0),
            pos(10.0, 10.0, 50),
            pos(20.0, 20.0, 100),
        ];
        let smoothed = smooth_cursor_path(&positions, 0.3);
        assert_eq!(smoothed[0].timestamp_ms, 0);
        assert_eq!(smoothed[1].timestamp_ms, 50);
        assert_eq!(smoothed[2].timestamp_ms, 100);
    }
}
