# DemoReel

Open-source macOS screen recorder. Hybrid Rust (core library) + SwiftUI (app).

## Build & Test

- `cd core && cargo test` — run all 52 Rust unit tests
- `cd core && cargo clippy -- -D warnings` — lint Rust code
- `cd core && cargo fmt -- --check` — check Rust formatting
- `./scripts/build-rust.sh` — build universal binary + generate Swift bindings
- `./scripts/setup.sh` — full dev environment setup
- Swift app builds via Xcode (`open app/DemoReel.xcodeproj`)

## Architecture

- `core/src/` — Rust library: zoom math, cursor smoothing, FFmpeg export, project files
- `app/DemoReel/` — SwiftUI app: Recording/, Editor/, Export/, Shared/
- Rust↔Swift bridge via UniFFI 0.28; bindings auto-generated to `app/DemoReel/Generated/`
- XcodeGen (`app/project.yml`) generates the .xcodeproj — edit project.yml, not .pbxproj

## Conventions

- Commit messages: `feat:`, `fix:`, `docs:`, `chore:` prefixes
- Rust: snake_case, `#[uniffi::export]` for public API, thiserror for errors
- Swift: @Observable for state, feature-based folder organization
- No Swift tests — only Rust unit tests exist
- FFmpeg is a runtime dependency for export (not linked at build time)
