# 1. Rust Build Pipeline (UniFFI + Static Library)

**Problem:** `lipo` failed creating universal binary — no `.a` file produced.

**Root cause:** `Cargo.toml` had `crate-type = ["cdylib", "lib"]` — missing `"staticlib"`. Without it, cargo only produces `.dylib` and rlib, not the `.a` file that `lipo` expects for universal binaries.

**Fix:** Add `"staticlib"` to crate-type:
```toml
crate-type = ["cdylib", "staticlib", "lib"]
```

**Lesson:** UniFFI needs `cdylib` for the dynamic library (used by bindgen) AND `staticlib` for the static library (linked into the Xcode project).
