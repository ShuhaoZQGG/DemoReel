# demoreel-core (Rust)

Pure computation library — no macOS dependencies. Builds on any platform.

## Build & Test

- `cargo test` — 63 unit tests across all modules
- `cargo clippy -- -D warnings` — lint
- `cargo fmt -- --check` — format check
- Tests use `approx` crate for floating-point comparisons

## Module Map

- `lib.rs` — Public API surface; all `#[uniffi::export]` functions live here
- `zoom.rs` — Auto-zoom from activity sessions (click + cursor velocity), cursor-following zoom centers
- `cursor.rs` — Cursor path smoothing (exponential moving average)
- `compositor.rs` — Frame dimensions, padding, aspect ratio calculations
- `export.rs` — FFmpeg command construction (does NOT call FFmpeg directly in tests)
- `project.rs` — .demoreel project file serialization (serde JSON)
- `types.rs` — All shared types, configs, and error enums

## Conventions

- New public API: add `#[uniffi::export]` fn in `lib.rs`, delegate to module
- Error types: use `thiserror` derive macros in `types.rs`
- Enums exposed to Swift: use `#[serde(tag = "type")]` for tagged serialization
- Tests: inline `#[cfg(test)] mod tests` in each module file
- Crate produces staticlib + cdylib + lib (all three needed for UniFFI + linking)
