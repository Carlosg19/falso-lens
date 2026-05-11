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
- Live audio transcription: independent microphone and computer-audio pipelines using `AVAudioEngine` + ScreenCaptureKit, chunked and normalized for local Whisper inference.
- Cross-source duplicate annotation across the two audio pipelines.
- User-picked WAV file transcription via the same Whisper inference layer.

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

Vision pipeline (one-shot screen → OCR → analysis):

```text
ContentView
  -> ScanPipeline
  -> ScreenCaptureService
  -> OCRService
  -> LocalHeuristicAnalyzer
  -> ScanStorage
  -> NotificationService
```

Hearing pipeline (real-time; two independent instances — microphone and computer audio):

```text
ContentView
  -> LiveAudioTranscriptionPipeline (x2)
       -> LiveAudioCaptureProvider (MicrophoneAudioCaptureProvider | ComputerAudioCaptureService)
       -> AudioBufferStore
       -> AudioChunker
       -> AudioNormalizer
       -> RMSVoiceActivityDetector
       -> WhisperCppEngine
  -> TranscriptDuplicateAnalyzer (cross-pipeline)
```

File-based transcription (user-picked WAV through the same Whisper engine):

```text
ContentView -> FileTranscriptionPipeline -> WhisperCppEngine
```

Key files:

- `falsoai-lens/ContentView.swift`
- `falsoai-lens/Pipelines/Vision/Services/ScanPipeline.swift`
- `falsoai-lens/Pipelines/Vision/Services/ScreenCaptureService.swift`
- `falsoai-lens/Pipelines/Vision/Services/OCRService.swift`
- `falsoai-lens/Pipelines/Hearing/Services/LiveAudioTranscriptionPipeline.swift`
- `falsoai-lens/Pipelines/Hearing/Services/FileTranscriptionPipeline.swift`
- `falsoai-lens/Pipelines/Hearing/Services/TranscriptDuplicateAnalyzer.swift`
- `falsoai-lens/Pipelines/Hearing/Inference/WhisperCppEngine.swift`
- `falsoai-lens/Pipelines/Hearing/Inference/RMSVoiceActivityDetector.swift`
- `falsoai-lens/Services/LocalHeuristicAnalyzer.swift`
- `falsoai-lens/Services/ScanStorage.swift`
- `falsoai-lens/Services/PermissionManager.swift`
- `falsoai-lens/Services/NotificationService.swift`

Keep capture, OCR, orchestration, analysis, storage, and notifications separated. Do not fold service logic directly into `ContentView`.

## Audio Pipeline

Implementation notes for the live audio pipelines:

- Capture: microphone via `AVAudioEngine`; computer audio via ScreenCaptureKit. Keep audio callbacks lightweight.
- Buffering: rolling buffer in `AudioBufferStore` (actor).
- Chunking: 5-second chunks with 1-second overlap.
- Normalization: 16 kHz mono PCM WAV via `AudioNormalizer`.
- VAD: `RMSVoiceActivityDetector` gates Whisper inference.
- Inference: bundled `whisper-cli` + `ggml-small.bin` (multilingual) invoked via Swift `Process`.
- Cleanup: temporary chunks are deleted after processing by default.

The historical design doc `docs/Live Audio Transcriber Architecture.md` predates the current two-pipeline architecture; the code is authoritative. Do not jump directly to native C/C++ Whisper bindings — the CLI-based pipeline is the current contract.

## Persistence

GRDB via `ScanStorage` is the only persistence layer; it owns scan history. Live transcripts and audio are not persisted — see Privacy below.

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
