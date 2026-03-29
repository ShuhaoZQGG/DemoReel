# Shared Module

- `AppState.swift` — `@Observable` app-wide state: screen routing (recording↔editor), file paths, trim bounds
- Recordings saved to `~/Movies/DemoReel/`
- State is ephemeral (no persistence); project save/load handled by EditorView
