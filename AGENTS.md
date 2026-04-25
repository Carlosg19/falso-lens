# AGENTS.md

Guidance for coding agents working in this repository.

## Project

`falsoai-lens` is a macOS SwiftUI application using SwiftData for persistence. Bundle ID is `com.falsoai.FalsoaiLens`, deployment target is macOS 26.2, and Swift version is 5.0.

This is currently a freshly scaffolded Xcode template. `Item` and `ContentView` are placeholder scaffolding, not established domain code.

## Build / Run

Open in Xcode:

```bash
open falsoai-lens.xcodeproj
```

Command-line build:

```bash
xcodebuild -project falsoai-lens.xcodeproj -scheme falsoai-lens -configuration Debug build
```

There is no test target configured yet. `xcodebuild test` will fail until one is added.

## Repository Notes

- The Xcode target uses a file-system synchronized group pointing at `falsoai-lens/`. New `.swift` files placed in that directory are picked up automatically. Do not edit `falsoai-lens.xcodeproj/project.pbxproj` just to register new source files.
- `falsoai-lens/falsoai_lensApp.swift` creates the app-wide persistent SwiftData `ModelContainer` and injects it with `.modelContainer(...)`.
- Add new `@Model` types to the `Schema([...])` array in `falsoai_lensApp.swift`, otherwise `@Query` will not see them.
- The project defaults to `MainActor` isolation with approachable concurrency enabled. Mark background work explicitly with `nonisolated`, a custom actor, or another appropriate isolation boundary.
- App Sandbox and Hardened Runtime are enabled. The app currently has read-only user-selected file access.
- `falsoai-lens/push_to_origin_main.sh` is a one-shot git helper that initializes git, sets `origin` to `git@github.com:Carlosg19/falso-lens.git`, commits pending changes, and force-renames the branch to `main`. Do not run it unless the user explicitly asks for that workflow.

## Agent Conduct

- Keep edits focused and consistent with the SwiftUI template style already present.
- Prefer adding Swift files under `falsoai-lens/` instead of manually changing Xcode project metadata.
- Do not overwrite unrelated local changes.
- Verify with `xcodebuild ... build` when making Swift code changes, unless the user asks for documentation-only edits or the local environment cannot build.
