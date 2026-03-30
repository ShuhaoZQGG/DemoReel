use crate::types::{EasingCurve, MouseEvent, SmoothedPoint, ZoomConfig, ZoomKeyframe};

/// An activity session: starts with a click, extends while cursor is moving.
struct ActivitySession {
    /// Timestamp of the first click that started this session.
    first_click_ms: u64,
    /// Position of the first click (used as fallback center).
    click_x: f64,
    click_y: f64,
    /// Timestamp of the last active event (click or fast movement).
    last_active_ms: u64,
}

/// Generate zoom keyframes from mouse events using default config.
pub fn generate_zoom_keyframes(events: &[MouseEvent]) -> Vec<ZoomKeyframe> {
    generate_zoom_keyframes_with_config(events, &ZoomConfig::default())
}

/// Generate zoom keyframes from mouse events with custom configuration.
///
/// Algorithm:
/// 1. A click starts a new activity session
/// 2. Cursor movement with velocity > threshold extends the session
/// 3. Additional clicks also extend the session
/// 4. Session ends when cursor is idle for idle_timeout_ms
/// 5. Each session becomes a keyframe with ease-in/hold/ease-out
pub fn generate_zoom_keyframes_with_config(
    events: &[MouseEvent],
    config: &ZoomConfig,
) -> Vec<ZoomKeyframe> {
    if !config.enabled {
        return Vec::new();
    }

    let sessions = detect_sessions(events, config);
    if sessions.is_empty() {
        return Vec::new();
    }

    // Convert sessions to keyframes
    let mut keyframes: Vec<ZoomKeyframe> = sessions
        .iter()
        .map(|session| {
            let start_ms = session.first_click_ms.saturating_sub(config.ease_in_ms);
            let session_hold = session.last_active_ms.saturating_sub(session.first_click_ms);
            let hold = session_hold.max(config.hold_ms);
            let total_duration = config.ease_in_ms + hold + config.ease_out_ms;
            ZoomKeyframe {
                start_ms,
                end_ms: start_ms.saturating_add(total_duration),
                center_x: session.click_x,
                center_y: session.click_y,
                scale: config.scale,
            }
        })
        .collect();

    // Merge overlapping keyframes
    merge_overlapping(&mut keyframes);

    keyframes
}

/// Detect activity sessions from mouse events.
///
/// A session starts on a click and extends while cursor is actively moving
/// or additional clicks occur. Ends after idle_timeout_ms of inactivity.
fn detect_sessions(events: &[MouseEvent], config: &ZoomConfig) -> Vec<ActivitySession> {
    let mut sessions: Vec<ActivitySession> = Vec::new();
    let mut current: Option<ActivitySession> = None;
    let mut prev_event: Option<&MouseEvent> = None;

    for event in events {
        // Check if the current session has timed out before processing this event
        if let Some(session) = &current {
            if event.timestamp_ms.saturating_sub(session.last_active_ms) > config.idle_timeout_ms {
                sessions.push(current.take().unwrap());
            }
        }

        if event.click {
            // A click starts or extends a session
            match &mut current {
                None => {
                    current = Some(ActivitySession {
                        first_click_ms: event.timestamp_ms,
                        click_x: event.x,
                        click_y: event.y,
                        last_active_ms: event.timestamp_ms,
                    });
                }
                Some(session) => {
                    session.last_active_ms = event.timestamp_ms;
                }
            }
        } else if let Some(session) = &mut current {
            // Movement event while in a session — check velocity
            let velocity = if let Some(prev) = prev_event {
                compute_velocity(prev, event)
            } else {
                0.0
            };

            if velocity > config.velocity_threshold {
                // Cursor is actively moving, extend session
                session.last_active_ms = event.timestamp_ms;
            }
        }

        prev_event = Some(event);
    }

    // Don't forget the last session
    if let Some(session) = current {
        sessions.push(session);
    }

    sessions
}

/// Compute cursor velocity (pixels/second) between two events.
fn compute_velocity(prev: &MouseEvent, curr: &MouseEvent) -> f64 {
    let dt_ms = curr.timestamp_ms.saturating_sub(prev.timestamp_ms);
    if dt_ms == 0 {
        return 0.0;
    }
    let dx = curr.x - prev.x;
    let dy = curr.y - prev.y;
    let distance = (dx * dx + dy * dy).sqrt();
    distance / (dt_ms as f64 / 1000.0)
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
            let eased = apply_easing(&config.easing_curve, t);
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
            let eased = apply_easing(&config.easing_curve, t);
            return kf.scale - (kf.scale - 1.0) * eased;
        }
    }

    1.0
}

/// Linear easing (no curve).
fn linear(t: f64) -> f64 {
    t.clamp(0.0, 1.0)
}

/// Cubic ease-in: accelerates from zero velocity.
fn ease_in(t: f64) -> f64 {
    let t = t.clamp(0.0, 1.0);
    t * t * t
}

/// Cubic ease-out: decelerates to zero velocity.
fn ease_out(t: f64) -> f64 {
    let t = t.clamp(0.0, 1.0);
    1.0 - (1.0 - t).powi(3)
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

/// Damped spring easing with slight overshoot.
fn spring(t: f64) -> f64 {
    let t = t.clamp(0.0, 1.0);
    if t == 0.0 {
        return 0.0;
    }
    if t == 1.0 {
        return 1.0;
    }
    let c4 = (2.0 * std::f64::consts::PI) / 3.0;
    2.0_f64.powf(-10.0 * t) * ((t * 10.0 - 0.75) * c4).sin() + 1.0
}

/// Dispatch to the appropriate easing function based on the curve type.
fn apply_easing(curve: &EasingCurve, t: f64) -> f64 {
    match curve {
        EasingCurve::Linear => linear(t),
        EasingCurve::EaseIn => ease_in(t),
        EasingCurve::EaseOut => ease_out(t),
        EasingCurve::EaseInOut => cubic_ease_in_out(t),
        EasingCurve::Spring => spring(t),
    }
}

/// Get the zoom center position at a given timestamp (static center from keyframe).
pub fn zoom_center_at(keyframes: &[ZoomKeyframe], timestamp_ms: u64) -> Option<(f64, f64)> {
    for kf in keyframes {
        if timestamp_ms >= kf.start_ms && timestamp_ms <= kf.end_ms {
            return Some((kf.center_x, kf.center_y));
        }
    }
    None
}

/// Get the zoom center that follows the cursor path during a zoom session.
///
/// During ease-in: interpolates from keyframe's static center toward cursor position.
/// During hold: returns the smoothed cursor position (center follows cursor).
/// During ease-out: holds the cursor position at the moment ease-out started.
pub fn zoom_center_at_with_path(
    keyframes: &[ZoomKeyframe],
    smoothed_path: &[SmoothedPoint],
    timestamp_ms: u64,
    config: &ZoomConfig,
) -> Option<(f64, f64)> {
    if !config.follow_cursor || smoothed_path.is_empty() {
        return zoom_center_at(keyframes, timestamp_ms);
    }

    for kf in keyframes {
        if timestamp_ms < kf.start_ms || timestamp_ms > kf.end_ms {
            continue;
        }

        let elapsed = timestamp_ms - kf.start_ms;
        let total = kf.end_ms - kf.start_ms;

        if elapsed <= config.ease_in_ms {
            // Ease in: blend from static center to cursor position
            let cursor = find_cursor_at(smoothed_path, timestamp_ms);
            let t = if config.ease_in_ms > 0 {
                apply_easing(&config.easing_curve, elapsed as f64 / config.ease_in_ms as f64)
            } else {
                1.0
            };
            let x = kf.center_x + (cursor.0 - kf.center_x) * t;
            let y = kf.center_y + (cursor.1 - kf.center_y) * t;
            return Some((x, y));
        } else if elapsed <= total.saturating_sub(config.ease_out_ms) {
            // Hold: follow cursor directly
            let cursor = find_cursor_at(smoothed_path, timestamp_ms);
            return Some(cursor);
        } else {
            // Ease out: hold the cursor position from when ease-out started
            let ease_out_start_ms = kf.start_ms + total.saturating_sub(config.ease_out_ms);
            let cursor = find_cursor_at(smoothed_path, ease_out_start_ms);
            return Some(cursor);
        }
    }

    None
}

/// Find the smoothed cursor position at a given timestamp via binary search.
fn find_cursor_at(path: &[SmoothedPoint], timestamp_ms: u64) -> (f64, f64) {
    if path.is_empty() {
        return (0.0, 0.0);
    }

    // Binary search for the last point with timestamp <= target
    let idx = match path.binary_search_by_key(&timestamp_ms, |p| p.timestamp_ms) {
        Ok(i) => i,
        Err(0) => 0,
        Err(i) => i - 1,
    };

    (path[idx].x, path[idx].y)
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
        // end = 700 + 300 + max(0, 600) + 400 = 2000
        assert_eq!(keyframes[0].end_ms, 2000);
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
        // Two clicks within a short time — second click extends the session
        let events = vec![
            click(100.0, 200.0, 1000),
            click(120.0, 220.0, 1200), // within idle_timeout (500ms)
        ];
        let config = default_config();
        let keyframes = generate_zoom_keyframes_with_config(&events, &config);
        assert_eq!(keyframes.len(), 1);
        // Center is the first click position (session start)
        assert_eq!(keyframes[0].center_x, 100.0);
        assert_eq!(keyframes[0].center_y, 200.0);
    }

    #[test]
    fn distant_clicks_produce_separate_keyframes() {
        let events = vec![
            click(100.0, 200.0, 1000),
            click(500.0, 600.0, 5000), // well beyond idle timeout
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
            click(200.0, 300.0, 2000),
        ];
        let mut config = default_config();
        config.idle_timeout_ms = 100; // short timeout so they're separate sessions
        config.ease_in_ms = 300;
        config.hold_ms = 600;
        config.ease_out_ms = 400;
        // Session 1: click at 1000, no subsequent activity → hold=600
        // kf1: start=700, end=700+300+600+400=2000
        // Session 2: click at 2000, no subsequent activity → hold=600
        // kf2: start=1700, end=1700+300+600+400=3000
        // They overlap → merge
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
        // With default config: first click at 1000, moves at 1500/2000 have high velocity
        // so they extend the session. Then idle from 2000..5000 (3000ms > 500ms timeout)
        // → session ends. Second click at 5000 starts a new session.
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

    // --- New tests for session-based detection ---

    #[test]
    fn cursor_movement_extends_session() {
        // Click, then fast cursor movement — should be one extended session
        let events = vec![
            click(100.0, 200.0, 1000),
            movement(200.0, 200.0, 1100), // 100px in 100ms = 1000 px/s (fast)
            movement(300.0, 200.0, 1200), // still fast
            movement(400.0, 200.0, 1300), // still fast
        ];
        let config = default_config();
        let keyframes = generate_zoom_keyframes_with_config(&events, &config);
        assert_eq!(keyframes.len(), 1);
        // Session should extend to 1300ms (last active movement)
        // hold = max(1300 - 1000, 600) = 600
        // start = 700, end = 700 + 300 + 600 + 400 = 2000
        assert_eq!(keyframes[0].start_ms, 700);
        assert!(keyframes[0].end_ms >= 2000);
    }

    #[test]
    fn slow_movement_does_not_extend_session() {
        // Click, then very slow movement — session should not extend
        let events = vec![
            click(100.0, 200.0, 1000),
            movement(101.0, 200.0, 2000), // 1px in 1000ms = 1 px/s (slow)
        ];
        let mut config = default_config();
        config.idle_timeout_ms = 500;
        config.velocity_threshold = 50.0;
        let keyframes = generate_zoom_keyframes_with_config(&events, &config);
        assert_eq!(keyframes.len(), 1);
        // Session should NOT be extended by the slow movement
        // hold = max(0, 600) = 600
        assert_eq!(keyframes[0].start_ms, 700);
        assert_eq!(keyframes[0].end_ms, 2000); // 700 + 300 + 600 + 400
    }

    #[test]
    fn session_ends_on_idle_timeout() {
        // Click, fast movement, then long pause, then another click
        let events = vec![
            click(100.0, 200.0, 1000),
            movement(200.0, 200.0, 1100), // fast
            movement(200.0, 200.0, 2000), // idle for 900ms > 500ms timeout
            click(500.0, 500.0, 3000),
        ];
        let config = default_config();
        let keyframes = generate_zoom_keyframes_with_config(&events, &config);
        assert_eq!(keyframes.len(), 2);
    }

    #[test]
    fn cursor_following_during_hold() {
        let keyframes = vec![ZoomKeyframe {
            start_ms: 700,
            end_ms: 2000,
            center_x: 100.0,
            center_y: 200.0,
            scale: 2.0,
        }];
        let path = vec![
            SmoothedPoint { x: 100.0, y: 200.0, timestamp_ms: 700, velocity: 0.0 },
            SmoothedPoint { x: 150.0, y: 250.0, timestamp_ms: 1000, velocity: 100.0 },
            SmoothedPoint { x: 300.0, y: 400.0, timestamp_ms: 1200, velocity: 200.0 },
        ];
        let config = default_config();
        // During hold phase (after ease_in of 300ms, so 1000..1600)
        let center = zoom_center_at_with_path(&keyframes, &path, 1200, &config);
        assert!(center.is_some());
        let (x, y) = center.unwrap();
        // Should follow cursor at t=1200 → (300, 400)
        assert!((x - 300.0).abs() < 0.01);
        assert!((y - 400.0).abs() < 0.01);
    }

    #[test]
    fn cursor_following_ease_in_blends() {
        let keyframes = vec![ZoomKeyframe {
            start_ms: 700,
            end_ms: 2000,
            center_x: 100.0,
            center_y: 200.0,
            scale: 2.0,
        }];
        let path = vec![
            SmoothedPoint { x: 200.0, y: 300.0, timestamp_ms: 700, velocity: 100.0 },
            SmoothedPoint { x: 200.0, y: 300.0, timestamp_ms: 1000, velocity: 0.0 },
        ];
        let config = default_config();
        // At start of ease-in (t=700), should be at keyframe center
        let center = zoom_center_at_with_path(&keyframes, &path, 700, &config);
        let (x, y) = center.unwrap();
        assert!((x - 100.0).abs() < 0.01);
        assert!((y - 200.0).abs() < 0.01);

        // At end of ease-in (t=1000), should be close to cursor position
        let center = zoom_center_at_with_path(&keyframes, &path, 999, &config);
        let (x, y) = center.unwrap();
        assert!((x - 200.0).abs() < 5.0); // close to cursor
        assert!((y - 300.0).abs() < 5.0);
    }

    #[test]
    fn cursor_following_disabled_returns_static() {
        let keyframes = vec![ZoomKeyframe {
            start_ms: 700,
            end_ms: 2000,
            center_x: 100.0,
            center_y: 200.0,
            scale: 2.0,
        }];
        let path = vec![
            SmoothedPoint { x: 500.0, y: 500.0, timestamp_ms: 1200, velocity: 0.0 },
        ];
        let mut config = default_config();
        config.follow_cursor = false;
        let center = zoom_center_at_with_path(&keyframes, &path, 1200, &config);
        let (x, y) = center.unwrap();
        // Should return static center, not cursor position
        assert_eq!(x, 100.0);
        assert_eq!(y, 200.0);
    }

    #[test]
    fn find_cursor_binary_search() {
        let path = vec![
            SmoothedPoint { x: 10.0, y: 20.0, timestamp_ms: 100, velocity: 0.0 },
            SmoothedPoint { x: 30.0, y: 40.0, timestamp_ms: 200, velocity: 50.0 },
            SmoothedPoint { x: 50.0, y: 60.0, timestamp_ms: 300, velocity: 50.0 },
        ];
        // Exact match
        assert_eq!(find_cursor_at(&path, 200), (30.0, 40.0));
        // Between points — should return the earlier one
        assert_eq!(find_cursor_at(&path, 250), (30.0, 40.0));
        // Before first point
        assert_eq!(find_cursor_at(&path, 50), (10.0, 20.0));
        // After last point
        assert_eq!(find_cursor_at(&path, 500), (50.0, 60.0));
    }

    // --- Easing curve tests ---

    #[test]
    fn easing_functions_boundary_values() {
        assert!((linear(0.0) - 0.0).abs() < 1e-10);
        assert!((linear(1.0) - 1.0).abs() < 1e-10);
        assert!((ease_in(0.0) - 0.0).abs() < 1e-10);
        assert!((ease_in(1.0) - 1.0).abs() < 1e-10);
        assert!((ease_out(0.0) - 0.0).abs() < 1e-10);
        assert!((ease_out(1.0) - 1.0).abs() < 1e-10);
        assert!((cubic_ease_in_out(0.0) - 0.0).abs() < 1e-10);
        assert!((cubic_ease_in_out(1.0) - 1.0).abs() < 1e-10);
        assert!((spring(0.0) - 0.0).abs() < 1e-10);
        assert!((spring(1.0) - 1.0).abs() < 1e-10);
    }

    #[test]
    fn easing_functions_monotonic_except_spring() {
        for func in [linear, ease_in, ease_out, cubic_ease_in_out] {
            let mut prev = 0.0;
            for i in 0..=100 {
                let t = i as f64 / 100.0;
                let v = func(t);
                assert!(v >= prev - 1e-10, "Monotonicity violated at t={t}");
                prev = v;
            }
        }
    }

    #[test]
    fn spring_overshoots() {
        let mut found_overshoot = false;
        for i in 1..100 {
            let t = i as f64 / 100.0;
            if spring(t) > 1.0 {
                found_overshoot = true;
                break;
            }
        }
        assert!(found_overshoot, "Spring easing should overshoot 1.0");
    }

    #[test]
    fn apply_easing_dispatches_correctly() {
        let t = 0.5;
        assert_eq!(apply_easing(&EasingCurve::Linear, t), linear(t));
        assert_eq!(apply_easing(&EasingCurve::EaseIn, t), ease_in(t));
        assert_eq!(apply_easing(&EasingCurve::EaseOut, t), ease_out(t));
        assert_eq!(apply_easing(&EasingCurve::EaseInOut, t), cubic_ease_in_out(t));
        assert_eq!(apply_easing(&EasingCurve::Spring, t), spring(t));
    }

    #[test]
    fn zoom_scale_with_different_curves() {
        let keyframes = vec![ZoomKeyframe {
            start_ms: 700,
            end_ms: 2000,
            center_x: 0.0,
            center_y: 0.0,
            scale: 2.0,
        }];
        let mut config_linear = default_config();
        config_linear.easing_curve = EasingCurve::Linear;
        let scale_linear = zoom_scale_at(&keyframes, 850, &config_linear);

        let mut config_ease_in = default_config();
        config_ease_in.easing_curve = EasingCurve::EaseIn;
        let scale_ease_in = zoom_scale_at(&keyframes, 850, &config_ease_in);

        let config_default = default_config();
        let scale_ease_in_out = zoom_scale_at(&keyframes, 850, &config_default);

        assert!((scale_linear - 1.5).abs() < 0.01);
        assert!(scale_ease_in < scale_linear);
        assert!(scale_linear > 1.0 && scale_linear < 2.0);
        assert!(scale_ease_in > 1.0 && scale_ease_in < 2.0);
        assert!(scale_ease_in_out > 1.0 && scale_ease_in_out < 2.0);
    }
}
