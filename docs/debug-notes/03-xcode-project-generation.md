# 3. Xcode Project Generation (xcodegen)

**Problem:** No `.xcodeproj` file existed — only Swift source files.

**Solution:** Use `xcodegen` with a `project.yml` that configures:
- `LIBRARY_SEARCH_PATHS` → point to `core/target/universal`
- `SWIFT_INCLUDE_PATHS` → point to `Generated/` (for FFI modulemap)
- `OTHER_LDFLAGS` → `-ldemoreel_core`
- `OTHER_SWIFT_FLAGS` → `-Xcc -fmodule-map-file=...DemoReelCoreFFI.modulemap`

**Key lesson:** Since the generated `DemoReelCore.swift` is compiled in the same module as the app, `import DemoReelCore` must be removed from all Swift files. The `#if canImport(DemoReelCoreFFI)` in the generated code handles the FFI import.
