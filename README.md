# DemoReel

Open-source screen recorder for macOS that turns raw recordings into polished product demos. Record your screen, and the app automatically adds smooth zoom effects on clicks, cursor smoothing, beautiful backgrounds, and exports a publish-ready video.

Think "Screen Studio but open-source and free."

## Features

- **Screen Recording** — Record any window or display via ScreenCaptureKit
- **Auto-Zoom on Clicks** — Automatically generates zoom keyframes centered on mouse clicks with configurable easing
- **Cursor Smoothing** — Exponential moving average smoothing removes jittery cursor movement
- **Styling** — Background color/gradient, padding, corner radius, shadow, aspect ratio presets
- **Cursor Customization** — Circle highlight, system cursor, or hidden; configurable size and click highlight color
- **Timeline Editor** — Visual keyframe timeline with trim handles, playhead, and zoom controls
- **Export** — MP4, GIF, or WebM via FFmpeg with progress reporting
- **Project Save/Load** — Save your settings as `.demoreel` project files

## Architecture

Hybrid Rust + SwiftUI:

```
demoreel/
├── core/               # Rust library (demoreel-core)
│   └── src/
│       ├── lib.rs      # UniFFI exports
│       ├── zoom.rs     # Auto-zoom keyframe generation
│       ├── cursor.rs   # Cursor path smoothing
│       ├── compositor.rs # Frame compositing logic
│       ├── export.rs   # FFmpeg subprocess orchestration
│       ├── project.rs  # .demoreel project file format
│       └── types.rs    # Shared types and configs
├── app/                # SwiftUI macOS app
│   └── DemoReel/
│       ├── Recording/  # ScreenCaptureKit + CGEventTap
│       ├── Editor/     # Timeline, preview, style panels
│       ├── Export/      # Export sheet + progress
│       └── Shared/     # App state
└── scripts/            # Build and setup scripts
```

The Rust core is a pure computation library — it handles zoom math, cursor smoothing, compositing logic, FFmpeg orchestration, and project serialization. The Swift app handles all macOS-specific concerns: screen capture, UI, and playback.

The two sides communicate via [UniFFI](https://mozilla.github.io/uniffi-rs/) (Mozilla), which auto-generates idiomatic Swift bindings from Rust.

## Prerequisites

- **Rust** (1.75+): `curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh`
- **Xcode 16+** with macOS 14 SDK
- **FFmpeg**: `brew install ffmpeg`

## Quickstart

```bash
# Clone the repo
git clone https://github.com/shuhaozqgg/demoreel.git
cd demoreel

# Set up dev environment (installs targets, builds Rust, runs tests)
./scripts/setup.sh

# On macOS: build universal binary + Swift bindings
./scripts/build-rust.sh

# Open in Xcode
open app/DemoReel.xcodeproj
# Link core/target/universal/libdemoreel_core.a in Xcode
# Build and run
```

## Development

### Rust core (works on any platform)

```bash
cd core
cargo build       # Build
cargo test        # Run tests (52 tests)
cargo clippy      # Lint
cargo fmt         # Format
```

### Swift app (requires macOS)

Open `app/DemoReel.xcodeproj` in Xcode. The app requires macOS 14 (Sonoma) or later.

## Keyboard Shortcuts

| Shortcut | Action |
|----------|--------|
| Space | Play / Pause |
| Cmd+N | New Recording |
| Cmd+O | Open Project |
| Cmd+S | Save Project |
| Cmd+E | Export Video |

## License

MIT
