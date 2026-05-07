# AGENTS.md

Guidance for coding agents working in this repository.

## Engineering Discipline

- Do not apply quick fixes unless the user explicitly asks for a temporary workaround.
- Fix root causes, not symptoms.
- Write simple, maintainable code a senior engineer would approve.
- Re-read relevant files before editing.
- Before editing, do a brief meta-analysis:
  - What is the user actually trying to accomplish?
  - What is the likely root cause or architectural pressure?
  - Which files, call sites, and permissions are affected?
  - What could break?
  - How will this be verified?
- Work in phases, usually no more than 5 files per phase.
- Remove dead code in the touched area before refactoring.
- Split large tasks into phases; use parallel agents only for independent work when available.
- Read large files in chunks.
- Do not trust a single search result.
- Cross-check call sites, types, strings, imports, tests, and build settings.

## Project

`falsoai-lens` is a native macOS SwiftUI app for local-first manipulation-risk analysis.

Current implemented MVP:

- Permission dashboard for Screen Recording, Accessibility, Notifications, and Microphone.
- One-shot main-display capture using ScreenCaptureKit.
- OCR using Vision.
- Deterministic local manipulation-risk analysis.
- Scan persistence using GRDB.
- User notifications for high-risk scan results.

Planned/architected next pipeline:

- Live microphone transcription using AVAudioEngine.
- Audio chunking and normalization for local Whisper inference.
- Original-language transcription and translate-to-English modes.
- Transcript assembly, deduplication, copy, clear, and export.

Bundle ID: `com.falsoai.FalsoaiLens`.
Deployment target: macOS 26.2.
Swift version: 5.0.

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

## Current Architecture

The implemented demo pipeline is:

```text
ContentView
  -> DemoScanPipeline
  -> ScreenCaptureService
  -> OCRService
  -> LocalHeuristicAnalyzer
  -> ScanStorage
  -> NotificationService
```

Key files:

- `falsoai-lens/ContentView.swift`
- `falsoai-lens/Pipelines/Vision/Services/DemoScanPipeline.swift`
- `falsoai-lens/Pipelines/Vision/Services/ScreenCaptureService.swift`
- `falsoai-lens/Pipelines/Vision/Services/OCRService.swift`
- `falsoai-lens/Services/LocalHeuristicAnalyzer.swift`
- `falsoai-lens/Services/ScanStorage.swift`
- `falsoai-lens/Services/PermissionManager.swift`
- `falsoai-lens/Services/NotificationService.swift`

Keep capture, OCR, orchestration, analysis, storage, and notifications separated. Do not fold service logic directly into `ContentView`.

## Planned Audio Pipeline

Use `docs/Live Audio Transcriber Architecture.md` as the source of truth for the planned audio MVP.

MVP direction:

- Capture microphone audio with `AVAudioEngine`.
- Keep audio callbacks lightweight.
- Use a rolling audio buffer actor.
- Create 5-second chunks with 1-second overlap.
- Normalize chunks to 16 kHz mono PCM WAV.
- Call `whisper-cli` with Swift `Process`.
- Use the multilingual Whisper `base` model, not `base.en`.
- Keep audio local and delete temporary chunks by default.

Do not jump directly to native C/C++ Whisper bindings until the CLI-based MVP works.

## Persistence

The app currently uses two persistence approaches:

- SwiftData is configured in `falsoai_lensApp.swift`.
- GRDB is used for scan history through `ScanStorage`.

Use GRDB/`ScanStorage` for scan records unless intentionally migrating persistence. If adding new SwiftData `@Model` types, add them to the `Schema([...])` array in `falsoai_lensApp.swift`, otherwise `@Query` will not see them.

## Concurrency

The project defaults to `MainActor` isolation:

- `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`
- `SWIFT_APPROACHABLE_CONCURRENCY = YES`

Guidelines:

- Keep SwiftUI state and observable controllers on `@MainActor`.
- Mark CPU-heavy or background work explicitly with `nonisolated`, an actor, or a background task.
- Do not block audio callbacks, UI actions, or the main actor with OCR, Whisper, file conversion, or process execution.

## macOS Permissions

The app uses ScreenCaptureKit, Vision OCR, microphone permission checks, notifications, and accessibility checks.

When debugging Screen Recording permission:

- Check `PermissionManager.runtimeIdentity()`.
- Remember permission may be tied to the exact DerivedData app copy.
- If access is stale, quit the app, reset TCC, grant permission again, and reopen.

Useful reset command:

```bash
tccutil reset ScreenCapture com.falsoai.FalsoaiLens
```

## Privacy

Keep the app local-first and privacy-preserving.

- Do not upload screenshots, OCR text, audio, transcripts, or scan records unless explicitly requested.
- Do not persist raw audio by default.
- Delete temporary audio chunks after successful processing unless a debug mode explicitly preserves them.
- Clearly surface when recording or screen capture is active.

## Xcode Project Notes

The target uses a file-system synchronized group pointing at `falsoai-lens/`. New `.swift` files placed under that directory are picked up automatically.

Do not edit `falsoai-lens.xcodeproj/project.pbxproj` just to register new Swift source files.

App Sandbox and Hardened Runtime are enabled. Current entitlements include:

- App Sandbox
- Microphone input
- User-selected read-only file access
- Network client

Do not change entitlements unless the requested feature requires it.

## Verification

After Swift code changes, run:

```bash
xcodebuild -project falsoai-lens.xcodeproj -scheme falsoai-lens -configuration Debug build
```

Skip the build only for documentation-only changes or when local Xcode tooling cannot build.

## Do Not Run

Do not run `falsoai-lens/push_to_origin_main.sh` unless the user explicitly asks for that workflow.

That script initializes git, sets `origin` to `git@github.com:Carlosg19/falso-lens.git`, commits pending changes, and force-renames the branch to `main`.
