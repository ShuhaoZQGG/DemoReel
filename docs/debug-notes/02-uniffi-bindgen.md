# 2. UniFFI Bindgen Setup

**Problem:** `cargo run --bin uniffi-bindgen` failed — no binary target found.

**Root cause:** UniFFI 0.28 with proc-macro exports (`#[uniffi::export]`) requires an in-project bindgen binary. The old approach of `cargo run --features uniffi/cli` doesn't work.

**Fix:** Create `core/src/bin/uniffi-bindgen.rs`:
```rust
fn main() {
    uniffi::uniffi_bindgen_main()
}
```

**Also:** UniFFI can't handle `Result<T, String>` as a return type. Must use a proper error enum:
```rust
#[derive(uniffi::Error, thiserror::Error, Debug)]
pub enum ParseError {
    #[error("Invalid JSON: {message}")]
    InvalidJson { message: String },
}
```
