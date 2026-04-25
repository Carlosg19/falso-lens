# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

`falsoai-lens` is a macOS SwiftUI application using SwiftData for persistence. Bundle ID `com.falsoai.falsoai-lens`, deployment target macOS 26.2, Swift 5.0. The project is a freshly-scaffolded Xcode template — `Item` / `ContentView` are placeholder scaffolding, not real domain code.

## Build / Run

Open in Xcode:

```bash
open falsoai-lens.xcodeproj
```

Command-line build (Debug, default destination):

```bash
xcodebuild -project falsoai-lens.xcodeproj -scheme falsoai-lens -configuration Debug build
```

There is no test target configured yet — `xcodebuild test` will fail until one is added.

`falsoai-lens/push_to_origin_main.sh` is a one-shot helper that initializes git, sets `origin` to `git@github.com:Carlosg19/falso-lens.git`, commits any pending changes, and force-renames the branch to `main`. It auto-commits with generic messages ("Initial commit" / "Save work before push") — do not run it when there are uncommitted changes you care about staging thoughtfully.

## Architecture notes

- **File-system synchronized group.** The Xcode target uses `PBXFileSystemSynchronizedRootGroup` pointing at `falsoai-lens/`. New `.swift` files dropped into that directory are picked up automatically — you do not need to (and should not) edit `project.pbxproj` to register them. Editing the pbxproj by hand will likely break this.
- **SwiftData container is app-wide and persistent.** `falsoai_lensApp.swift` builds a single `ModelContainer` with `isStoredInMemoryOnly: false` and injects it via `.modelContainer(...)`. New `@Model` types must be added to the `Schema([...])` array there, otherwise `@Query` will not see them. `fatalError` is used on container failure — existing behavior, keep it unless the user asks otherwise.
- **MainActor by default.** `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` and `SWIFT_APPROACHABLE_CONCURRENCY = YES` are set, so every type/function is MainActor-isolated unless explicitly marked `nonisolated` or put on another actor. Expect to annotate background work explicitly.
- **App Sandbox + Hardened Runtime are on**, with `ENABLE_USER_SELECTED_FILES = readonly`. File system access beyond user-selected read is not permitted without changing entitlements.
