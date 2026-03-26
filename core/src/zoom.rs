use crate::types::{MouseEvent, ZoomConfig, ZoomKeyframe};

/// A cluster of nearby clicks that will become a single zoom keyframe.
struct ClickCluster {
    centroid_x: f64,
    centroid_y: f64,
    timestamp_ms: u64,
    count: usize,
}

impl ClickCluster {
    fn from_event(event: &MouseEvent) -> Self {
        ClickCluster {
            centroid_x: event.x,
            centroid_y: event.y,
            timestamp_ms: event.timestamp_ms,
            count: 1,
        }
    }

    fn merge(&mut self, event: &MouseEvent) {
        let total = self.count as f64 + 1.0;
        self.centroid_x =
            (self.centroid_x * self.count as f64 + event.x) / total;
        self.centroid_y =
            (self.centroid_y * self.count as f64 + event.y) / total;
        self.timestamp_ms = self.timestamp_ms.max(event.timestamp_ms);
        self.count += 1;
    }
}

/// Generate zoom keyframes from mouse events using default config.
pub fn generate_zoom_keyframes(events: &[MouseEvent]) -> Vec<ZoomKeyframe> {
    generate_zoom_keyframes_with_config(events, &ZoomConfig::default())
}

/// Generate zoom keyframes from mouse events with custom configuration.
///
/// Algorithm:
/// 1. Filter to click events only
/// 2. Cluster clicks within merge_threshold_ms into single groups
/// 3. Generate a keyframe per cluster with ease-in, hold, and ease-out
/// 4. Merge overlapping keyframes
pub fn generate_zoom_keyframes_with_config(
    events: &[MouseEvent],
    config: &ZoomConfig,
) -> Vec<ZoomKeyframe> {
    if !config.enabled {
        return Vec::new();
    }

    let clicks: Vec<&MouseEvent> = events.iter().filter(|e| e.click).collect();
    if clicks.is_empty() {
        return Vec::new();
    }

    // Step 1: Cluster nearby clicks
    let clusters = cluster_clicks(&clicks, config.merge_threshold_ms);

    // Step 2: Generate keyframes from clusters
    let mut keyframes: Vec<ZoomKeyframe> = clusters
        .iter()
        .map(|cluster| {
            let total_duration = config.ease_in_ms + config.hold_ms + config.ease_out_ms;
            ZoomKeyframe {
                start_ms: cluster.timestamp_ms.saturating_sub(config.ease_in_ms),
                end_ms: cluster
                    .timestamp_ms
                    .saturating_sub(config.ease_in_ms)
                    .saturating_add(total_duration),
                center_x: cluster.centroid_x,
                center_y: cluster.centroid_y,
                scale: config.scale,
            }
        })
        .collect();

    // Step 3: Merge overlapping keyframes
    merge_overlapping(&mut keyframes);

    keyframes
}

/// Group clicks that occur within threshold_ms of each other.
fn cluster_clicks(clicks: &[&MouseEvent], threshold_ms: u64) -> Vec<ClickCluster> {
    let mut clusters: Vec<ClickCluster> = Vec::new();

    for click in clicks {
        if let Some(last) = clusters.last_mut() {
            if click.timestamp_ms.saturating_sub(last.timestamp_ms) <= threshold_ms {
                last.merge(click);
                continue;
            }
        }
        clusters.push(ClickCluster::from_event(click));
    }

    clusters
}

/// Merge keyframes whose time ranges overlap.
fn merge_overlapping(keyframes: &mut Vec<ZoomKeyframe>) {
    if keyframes.len() < 2 {
        return;
    }

    let mut i = 0;
    while i + 1 < keyframes.len() {
        if keyframes[i].end_ms >= keyframes[i + 1].start_ms {
            let next = keyframes.remove(i + 1);
            keyframes[i].end_ms = keyframes[i].end_ms.max(next.end_ms);
            // Use weighted average for center position
            keyframes[i].center_x = (keyframes[i].center_x + next.center_x) / 2.0;
            keyframes[i].center_y = (keyframes[i].center_y + next.center_y) / 2.0;
            keyframes[i].scale = keyframes[i].scale.max(next.scale);
        } else {
            i += 1;
        }
    }
}

/// Compute the eased zoom scale at a given timestamp.
///
/// Returns 1.0 (no zoom) when outside any keyframe, and interpolates
/// smoothly during ease-in/hold/ease-out phases.
pub fn zoom_scale_at(keyframes: &[ZoomKeyframe], timestamp_ms: u64, config: &ZoomConfig) -> f64 {
    for kf in keyframes {
        if timestamp_ms < kf.start_ms || timestamp_ms > kf.end_ms {
            continue;
        }

        let elapsed = timestamp_ms - kf.start_ms;
        let total = kf.end_ms - kf.start_ms;

        if elapsed <= config.ease_in_ms {
            // Ease in
            let t = elapsed as f64 / config.ease_in_ms as f64;
            let eased = cubic_ease_in_out(t);
            return 1.0 + (kf.scale - 1.0) * eased;
        } else if elapsed <= config.ease_in_ms + config.hold_ms {
            // Hold at full scale
            return kf.scale;
        } else {
            // Ease out
            let ease_out_elapsed = elapsed - config.ease_in_ms - config.hold_ms;
            let remaining = total - config.ease_in_ms - config.hold_ms;
            if remaining == 0 {
                return 1.0;
            }
            let t = ease_out_elapsed as f64 / remaining as f64;
            let eased = cubic_ease_in_out(t);
            return kf.scale - (kf.scale - 1.0) * eased;
        }
    }

    1.0
}

/// Cubic ease-in-out: approximates cubic-bezier(0.25, 0.1, 0.25, 1.0).
fn cubic_ease_in_out(t: f64) -> f64 {
    let t = t.clamp(0.0, 1.0);
    if t < 0.5 {
        4.0 * t * t * t
    } else {
        1.0 - (-2.0 * t + 2.0).powi(3) / 2.0
    }
}

/// Get the zoom center position at a given timestamp, interpolating between keyframes.
pub fn zoom_center_at(keyframes: &[ZoomKeyframe], timestamp_ms: u64) -> Option<(f64, f64)> {
    for kf in keyframes {
        if timestamp_ms >= kf.start_ms && timestamp_ms <= kf.end_ms {
            return Some((kf.center_x, kf.center_y));
        }
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    fn default_config() -> ZoomConfig {
        ZoomConfig::default()
    }

    fn click(x: f64, y: f64, ts: u64) -> MouseEvent {
        MouseEvent {
            x,
            y,
            timestamp_ms: ts,
            click: true,
        }
    }

    fn movement(x: f64, y: f64, ts: u64) -> MouseEvent {
        MouseEvent {
            x,
            y,
            timestamp_ms: ts,
            click: false,
        }
    }

    #[test]
    fn empty_events_returns_empty_keyframes() {
        let result = generate_zoom_keyframes(&[]);
        assert!(result.is_empty());
    }

    #[test]
    fn single_click_generates_keyframe() {
        let events = vec![click(100.0, 200.0, 1000)];
        let config = default_config();
        let keyframes = generate_zoom_keyframes_with_config(&events, &config);
        assert_eq!(keyframes.len(), 1);
        assert_eq!(keyframes[0].center_x, 100.0);
        assert_eq!(keyframes[0].center_y, 200.0);
        assert_eq!(keyframes[0].start_ms, 700); // 1000 - 300 ease_in
        assert_eq!(keyframes[0].end_ms, 2000); // 700 + 300 + 600 + 400
        assert_eq!(keyframes[0].scale, 2.0);
    }

    #[test]
    fn non_click_events_ignored() {
        let events = vec![movement(50.0, 50.0, 100), movement(150.0, 150.0, 200)];
        let keyframes = generate_zoom_keyframes(&events);
        assert!(keyframes.is_empty());
    }

    #[test]
    fn nearby_clicks_are_clustered() {
        let events = vec![
            click(100.0, 200.0, 1000),
            click(120.0, 220.0, 1200), // within 300ms threshold
        ];
        let config = default_config();
        let keyframes = generate_zoom_keyframes_with_config(&events, &config);
        assert_eq!(keyframes.len(), 1);
        // Centroid of (100,200) and (120,220)
        assert!((keyframes[0].center_x - 110.0).abs() < 0.01);
        assert!((keyframes[0].center_y - 210.0).abs() < 0.01);
    }

    #[test]
    fn distant_clicks_produce_separate_keyframes() {
        let events = vec![
            click(100.0, 200.0, 1000),
            click(500.0, 600.0, 5000), // well beyond threshold
        ];
        let config = default_config();
        let keyframes = generate_zoom_keyframes_with_config(&events, &config);
        assert_eq!(keyframes.len(), 2);
        assert_eq!(keyframes[0].center_x, 100.0);
        assert_eq!(keyframes[1].center_x, 500.0);
    }

    #[test]
    fn overlapping_keyframes_are_merged() {
        // Two clicks close enough that their keyframe time ranges overlap
        let events = vec![
            click(100.0, 200.0, 1000),
            click(200.0, 300.0, 2000), // separate clusters but overlapping keyframes
        ];
        let mut config = default_config();
        config.merge_threshold_ms = 100; // don't cluster, but keyframes will overlap
        config.ease_in_ms = 300;
        config.hold_ms = 600;
        config.ease_out_ms = 400;
        // kf1: 700..2000, kf2: 1700..3000 → overlap → merge
        let keyframes = generate_zoom_keyframes_with_config(&events, &config);
        assert_eq!(keyframes.len(), 1);
        assert_eq!(keyframes[0].start_ms, 700);
        assert_eq!(keyframes[0].end_ms, 3000);
    }

    #[test]
    fn disabled_config_returns_empty() {
        let events = vec![click(100.0, 200.0, 1000)];
        let mut config = default_config();
        config.enabled = false;
        let keyframes = generate_zoom_keyframes_with_config(&events, &config);
        assert!(keyframes.is_empty());
    }

    #[test]
    fn early_click_saturates_start_ms() {
        let events = vec![click(0.0, 0.0, 100)];
        let keyframes = generate_zoom_keyframes(&events);
        assert_eq!(keyframes[0].start_ms, 0);
    }

    #[test]
    fn zoom_scale_outside_keyframes_is_one() {
        let keyframes = vec![ZoomKeyframe {
            start_ms: 1000,
            end_ms: 2000,
            center_x: 0.0,
            center_y: 0.0,
            scale: 2.0,
        }];
        let config = default_config();
        assert_eq!(zoom_scale_at(&keyframes, 500, &config), 1.0);
        assert_eq!(zoom_scale_at(&keyframes, 3000, &config), 1.0);
    }

    #[test]
    fn zoom_scale_during_hold_is_full() {
        let config = default_config();
        let keyframes = vec![ZoomKeyframe {
            start_ms: 700,
            end_ms: 2000,
            center_x: 0.0,
            center_y: 0.0,
            scale: 2.0,
        }];
        // Hold phase: ease_in(300ms) from 700..1000, hold from 1000..1600
        assert_eq!(zoom_scale_at(&keyframes, 1200, &config), 2.0);
    }

    #[test]
    fn zoom_scale_ease_in_starts_at_one() {
        let config = default_config();
        let keyframes = vec![ZoomKeyframe {
            start_ms: 700,
            end_ms: 2000,
            center_x: 0.0,
            center_y: 0.0,
            scale: 2.0,
        }];
        let scale = zoom_scale_at(&keyframes, 700, &config);
        assert!((scale - 1.0).abs() < 0.01);
    }

    #[test]
    fn zoom_center_returns_none_outside_keyframes() {
        let keyframes = vec![ZoomKeyframe {
            start_ms: 1000,
            end_ms: 2000,
            center_x: 100.0,
            center_y: 200.0,
            scale: 2.0,
        }];
        assert!(zoom_center_at(&keyframes, 500).is_none());
        assert_eq!(zoom_center_at(&keyframes, 1500), Some((100.0, 200.0)));
    }

    #[test]
    fn multiple_clicks_with_moves_between() {
        let events = vec![
            movement(10.0, 10.0, 0),
            click(100.0, 200.0, 1000),
            movement(150.0, 250.0, 1500),
            movement(200.0, 300.0, 2000),
            click(400.0, 500.0, 5000),
            movement(410.0, 510.0, 5500),
        ];
        let keyframes = generate_zoom_keyframes(&events);
        assert_eq!(keyframes.len(), 2);
    }

    #[test]
    fn custom_scale() {
        let events = vec![click(100.0, 200.0, 1000)];
        let mut config = default_config();
        config.scale = 3.0;
        let keyframes = generate_zoom_keyframes_with_config(&events, &config);
        assert_eq!(keyframes[0].scale, 3.0);
    }
}
