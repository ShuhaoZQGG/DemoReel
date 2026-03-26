# DemoReel — Getting Started & Testing Guide

## Prerequisites

| Requirement | Install | Notes |
|-------------|---------|-------|
| Rust 1.75+ | `curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs \| sh` | Required for core library |
| Xcode 16+ | Mac App Store | Required for Swift app (macOS only) |
| macOS 14+ | — | Minimum deployment target |
| FFmpeg | `brew install ffmpeg` | Required for video export |

## Quick Start (One Command)

```bash
git clone https://github.com/shuhaozqgg/demoreel.git
cd demoreel
./scripts/setup.sh
```

This will:
1. Verify Rust is installed
2. Build the Rust core library
3. Run all 52 unit tests
4. (macOS) Add cross-compilation targets, build universal binary, generate Swift bindings

## Step-by-Step Setup

### 1. Build the Rust Core

Works on any platform (macOS, Linux):

```bash
cd core
cargo build
```

Expected output: `Finished dev profile` with no errors.

### 2. Run All Tests

```bash
cd core
cargo test
```

Expected output:

```
running 52 tests
test compositor::tests::auto_aspect_adds_padding_only ... ok
test compositor::tests::default_style_config_is_valid ... ok
test compositor::tests::landscape_16x9_widens_if_needed ... ok
...
test project::tests::save_and_load_roundtrip ... ok
test project::tests::load_nonexistent_file_returns_error ... ok
...
test zoom::tests::single_click_generates_keyframe ... ok
test zoom::tests::zoom_scale_during_hold_is_full ... ok
...
test result: ok. 52 passed; 0 failed; 0 ignored
```

### 3. Run Linter

```bash
cd core
cargo clippy -- -D warnings
```

Expected: no warnings or errors.

### 4. Format Check

```bash
cd core
cargo fmt -- --check
```

Expected: no output (already formatted).

### 5. Build Universal Binary (macOS Only)

```bash
./scripts/build-rust.sh
```

This produces:
- `core/target/universal/libdemoreel_core.a` — universal static library (ARM64 + x86_64)
- `app/DemoReel/Generated/*.swift` — auto-generated Swift bindings

### 6. Run the App (macOS Only)

```bash
open app/DemoReel.xcodeproj
```

In Xcode:
1. Go to project settings → Build Phases → Link Binary With Libraries
2. Add `core/target/universal/libdemoreel_core.a`
3. Build and Run (Cmd+R)

The app should launch showing the recording screen with a window picker.

## Test Breakdown by Module

### Zoom Engine (`zoom.rs`) — 13 tests

Tests the auto-zoom keyframe generation algorithm:

| Test | What it verifies |
|------|-----------------|
| `empty_events_returns_empty_keyframes` | No events → no keyframes |
| `single_click_generates_keyframe` | One click → one keyframe with correct timing |
| `non_click_events_ignored` | Mouse moves don't generate keyframes |
| `nearby_clicks_are_clustered` | Clicks within 300ms merge into one keyframe |
| `distant_clicks_produce_separate_keyframes` | Clicks far apart stay separate |
| `overlapping_keyframes_are_merged` | Overlapping time ranges merge |
| `disabled_config_returns_empty` | `enabled: false` → no output |
| `early_click_saturates_start_ms` | Click at t=100ms doesn't underflow to negative |
| `zoom_scale_outside_keyframes_is_one` | No zoom (1.0x) between keyframes |
| `zoom_scale_during_hold_is_full` | Full zoom during hold phase |
| `zoom_scale_ease_in_starts_at_one` | Ease-in begins at 1.0x |
| `zoom_center_returns_none_outside_keyframes` | No center when not zoomed |
| `multiple_clicks_with_moves_between` | Moves between clicks don't interfere |
| `custom_scale` | Custom scale value is respected |

### Cursor Smoothing (`cursor.rs`) — 6 tests

Tests the exponential moving average cursor smoother:

| Test | What it verifies |
|------|-----------------|
| `empty_input_returns_empty` | No points → no output |
| `single_point_returns_same` | One point passes through unchanged |
| `smoothing_reduces_jitter` | Smoothed range < raw range |
| `alpha_one_passes_through` | Alpha=1.0 means no smoothing |
| `low_alpha_smooths_more` | Lower alpha = smoother output |
| `velocity_is_computed` | Speed calculated from position deltas |
| `timestamps_are_preserved` | Original timestamps unchanged |

### Compositor (`compositor.rs`) — 11 tests

Tests output dimension calculation and color parsing:

| Test | What it verifies |
|------|-----------------|
| `auto_aspect_adds_padding_only` | "auto" ratio just adds padding |
| `landscape_16x9_widens_if_needed` | 4:3 source → widened for 16:9 |
| `square_aspect_ratio` | Wide source → height increased for 1:1 |
| `portrait_9x16` | Landscape → much taller for portrait |
| `zero_padding` | No padding → source dimensions unchanged |
| `parse_hex_6_digit` | `#1a1a2e` → (26, 26, 46, 255) |
| `parse_hex_3_digit` | `#fff` → (255, 255, 255, 255) |
| `parse_hex_8_digit_with_alpha` | `#ff000080` → (255, 0, 0, 128) |
| `parse_hex_no_hash` | `3b82f6` works without `#` prefix |
| `parse_hex_invalid` | `#xyz` and wrong lengths return errors |
| `default_style_config_is_valid` | Default config has parseable colors |

### Export Pipeline (`export.rs`) — 8 tests

Tests FFmpeg command construction (does not require FFmpeg installed):

| Test | What it verifies |
|------|-----------------|
| `build_ffmpeg_args_mp4` | MP4 uses libx264, includes -y, -i, output path |
| `build_ffmpeg_args_gif` | GIF uses `-f gif`, no audio stream |
| `build_ffmpeg_args_webm` | WebM uses libvpx-vp9, includes audio |
| `build_filter_complex_includes_scale_and_overlay` | Filter has scale + overlay + color |
| `build_filter_complex_with_corner_radius` | Corner radius adds geq filter |
| `build_filter_complex_no_corner_radius` | Zero radius uses null filter |
| `build_ffmpeg_args_uses_config_fps` | Custom FPS (60) is used |
| `build_ffmpeg_args_uses_source_fps_when_zero` | FPS=0 falls back to source |

### Project Save/Load (`project.rs`) — 5 tests

Tests .demoreel project file serialization:

| Test | What it verifies |
|------|-----------------|
| `save_and_load_roundtrip` | Save → load → all fields match |
| `load_nonexistent_file_returns_error` | Missing file → IoError |
| `load_invalid_json_returns_error` | Bad JSON → ParseError |
| `load_version_zero_returns_error` | Version 0 → InvalidProject |
| `saved_file_is_valid_json` | Saved file is parseable JSON with correct values |

### Integration (`lib.rs`) — 9 tests

Tests end-to-end flows across modules:

| Test | What it verifies |
|------|-----------------|
| `core_version_is_not_empty` | Version string exists |
| `core_version_matches_cargo` | Version equals "0.1.0" |
| `parse_event_log_roundtrip` | JSON → EventLogRecord with all fields |
| `mouse_events_from_log_converts_all` | Event log → MouseEvents with click flags |
| `parse_event_log_invalid_json` | Bad JSON → error |
| `end_to_end_log_to_keyframes` | JSON → mouse events → zoom keyframes |
| `end_to_end_log_to_smoothed_cursor` | JSON → mouse events → smoothed path |

## Running Individual Test Modules

```bash
# Run only zoom tests
cargo test zoom::

# Run only cursor tests
cargo test cursor::

# Run only compositor tests
cargo test compositor::

# Run only export tests
cargo test export::

# Run only project tests
cargo test project::

# Run a specific test
cargo test project::tests::save_and_load_roundtrip
```

## Testing the Full App (macOS)

### Recording Flow

1. Launch the app
2. Grant Screen Recording permission (System Settings → Privacy & Security → Screen Recording)
3. Select a window from the dropdown
4. Click **Record** → perform actions → click **Stop**
5. Verify: `~/Movies/DemoReel/` contains a `.mov` and `.events.json` file

### Editor Flow

1. After recording stops, the editor opens automatically
2. Verify: zoom keyframes appear as blue rectangles on the timeline
3. Press **Space** to play/pause
4. Drag the orange trim handles to adjust start/end
5. Switch sidebar tabs: Zoom, Style, Cursor
6. Adjust settings and verify preview updates in real-time

### Export Flow

1. Click **Export** (or Cmd+E)
2. Select format (MP4/GIF/WebM) and resolution
3. Click **Export** → verify progress bar advances
4. On completion, click **Reveal in Finder**
5. Play the exported file in QuickTime to verify

### Project Save/Load Flow

1. In the editor, press **Cmd+S** → choose a save location
2. Verify a `.demoreel` file is created (open in text editor — it's JSON)
3. Press **Cmd+N** to start a new recording
4. Press **Cmd+O** → open the saved `.demoreel` file
5. Verify all settings (zoom, style, cursor, trim) are restored

## Keyboard Shortcuts

| Shortcut | Action | Where |
|----------|--------|-------|
| Space | Play / Pause | Editor |
| Cmd+N | New Recording | Anywhere |
| Cmd+O | Open Project | Anywhere |
| Cmd+S | Save Project | Editor |
| Cmd+E | Export Video | Editor |

## Troubleshooting

### `cargo build` fails with UniFFI errors
Ensure you're using uniffi 0.28. Check `core/Cargo.toml` for the pinned version.

### FFmpeg not found during export
Install FFmpeg: `brew install ffmpeg`. Verify with `which ffmpeg`.

### Screen Recording permission denied
Go to System Settings → Privacy & Security → Screen Recording → enable DemoReel.

### Swift bindings out of date
Re-generate: `./scripts/generate-bindings.sh` (requires prior `./scripts/build-rust.sh`).

### Tests fail with file permission errors
The project save/load tests write to the system temp directory. Ensure `/tmp` is writable.
