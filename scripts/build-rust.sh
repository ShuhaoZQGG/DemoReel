#!/bin/bash
# Build Rust core as a universal macOS static library and generate Swift bindings.
# Usage: ./scripts/build-rust.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CORE_DIR="$ROOT_DIR/core"
OUT_DIR="$ROOT_DIR/app/DemoReel/Generated"

if [[ "$(uname)" != "Darwin" ]]; then
    echo "Error: This script requires macOS (for Apple target compilation)."
    echo "On Linux, use 'cargo build' and 'cargo test' in core/ directly."
    exit 1
fi

echo "Building for aarch64-apple-darwin..."
cargo build --release --target aarch64-apple-darwin --manifest-path "$CORE_DIR/Cargo.toml"

echo "Building for x86_64-apple-darwin..."
cargo build --release --target x86_64-apple-darwin --manifest-path "$CORE_DIR/Cargo.toml"

echo "Creating universal binary..."
mkdir -p "$CORE_DIR/target/universal"
lipo -create \
    "$CORE_DIR/target/aarch64-apple-darwin/release/libdemoreel_core.a" \
    "$CORE_DIR/target/x86_64-apple-darwin/release/libdemoreel_core.a" \
    -output "$CORE_DIR/target/universal/libdemoreel_core.a"

echo "Generating Swift bindings..."
mkdir -p "$OUT_DIR"
cargo run --manifest-path "$CORE_DIR/Cargo.toml" \
    --features uniffi/cli \
    --bin uniffi-bindgen generate \
    --library "$CORE_DIR/target/aarch64-apple-darwin/release/libdemoreel_core.dylib" \
    --language swift \
    --out-dir "$OUT_DIR"

echo "Done."
echo "  Universal lib: $CORE_DIR/target/universal/libdemoreel_core.a"
echo "  Swift bindings: $OUT_DIR/"
