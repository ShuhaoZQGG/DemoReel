#!/bin/bash
# Generate Swift bindings from the Rust core library (requires prior build).
# Usage: ./scripts/generate-bindings.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CORE_DIR="$ROOT_DIR/core"
OUT_DIR="$ROOT_DIR/app/DemoReel/Generated"

if [[ "$(uname)" != "Darwin" ]]; then
    echo "Error: Swift binding generation requires macOS."
    exit 1
fi

LIB_PATH="$CORE_DIR/target/aarch64-apple-darwin/release/libdemoreel_core.dylib"
if [[ ! -f "$LIB_PATH" ]]; then
    echo "Error: Library not found at $LIB_PATH"
    echo "Run ./scripts/build-rust.sh first."
    exit 1
fi

echo "Generating Swift bindings..."
mkdir -p "$OUT_DIR"
cargo run --manifest-path "$CORE_DIR/Cargo.toml" \
    --features uniffi/cli \
    --bin uniffi-bindgen generate \
    --library "$LIB_PATH" \
    --language swift \
    --out-dir "$OUT_DIR"

echo "Swift bindings written to: $OUT_DIR/"
