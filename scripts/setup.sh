#!/bin/bash
# One-command dev environment setup for DemoReel.
# Usage: ./scripts/setup.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

echo "=== DemoReel Dev Setup ==="

# Check Rust
if ! command -v rustc &> /dev/null; then
    echo "Error: Rust not found. Install from https://rustup.rs"
    exit 1
fi
echo "Rust: $(rustc --version)"
echo "Cargo: $(cargo --version)"

# Build Rust core
echo ""
echo "Building Rust core..."
cargo build --manifest-path "$ROOT_DIR/core/Cargo.toml"

# Run tests
echo ""
echo "Running Rust tests..."
cargo test --manifest-path "$ROOT_DIR/core/Cargo.toml"

# macOS-specific setup
if [[ "$(uname)" == "Darwin" ]]; then
    echo ""
    echo "Adding macOS cross-compilation targets..."
    rustup target add aarch64-apple-darwin x86_64-apple-darwin

    # Check FFmpeg
    if command -v ffmpeg &> /dev/null; then
        echo "FFmpeg: $(ffmpeg -version 2>&1 | head -1)"
    else
        echo "Warning: FFmpeg not found. Install with: brew install ffmpeg"
    fi

    echo ""
    echo "Building universal binary + Swift bindings..."
    "$SCRIPT_DIR/build-rust.sh"
fi

echo ""
echo "=== Setup complete ==="
echo "Next steps:"
if [[ "$(uname)" == "Darwin" ]]; then
    echo "  1. Open app/DemoReel.xcodeproj in Xcode"
    echo "  2. Link core/target/universal/libdemoreel_core.a"
    echo "  3. Build and run"
else
    echo "  Rust core builds and tests pass."
    echo "  To build the full app, switch to macOS."
fi
