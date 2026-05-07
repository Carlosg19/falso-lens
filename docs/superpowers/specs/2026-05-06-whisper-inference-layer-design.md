# Whisper Inference Layer — Design Spec

**Date:** 2026-05-06
**Status:** Approved (design only; implementation plan to follow)
**Scope:** [Live Audio Transcriber Architecture §4.5](../../../docs/Live%20Audio%20Transcriber%20Architecture.md), §8, §9.

## 1. Purpose

Implement the Whisper Inference Layer — the unit that converts a normalized 16 kHz mono PCM WAV file into transcribed (or English-translated) text. The layer plugs into the existing Hearing pipeline scaffold by consuming a `URL` (matching `NormalizedAudioChunk.fileURL`) and returning a structured `TranscriptionResult`. It is the only inference component the app needs to graduate the audio capture/normalization scaffold from "produces WAV files" to "produces transcripts."

This spec covers the inference layer in isolation plus the minimum verification surface (a manual demo orchestrator and a ContentView section). It does **not** wire the layer to live microphone capture; that is a separate plan once this layer is verified.

## 2. Decisions Locked During Brainstorming

| # | Decision | Rationale |
|---|---|---|
| 1 | Scope = inference layer + `HearingDemoPipeline` orchestrator + `ContentView` demo section. | Audio capture/buffer/chunking/normalization scaffolds already exist; this is the missing piece. |
| 2 | Bundle `whisper-cli` and `ggml-base.bin` inside the .app. | Honors local-first/privacy posture; sandbox stays on; avoids absolute homebrew paths. |
| 3 | `whisper-cli` is built **from source as a self-contained static binary** via a reproducible script. | Homebrew binary depends on `@rpath`/`/opt/homebrew/...` dylibs and is ad-hoc signed; bundling it directly is fragile. |
| 4 | Parse `whisper-cli` JSON output (`-oj`), not plain text. | The `TranscriptionResult` struct in the architecture doc was designed around JSON shape (segments, timestamps, language). |
| 5 | Engine internals are **self-contained** (no separate `ProcessRunner`). | YAGNI — single consumer of `Process` exists. Extract `ProcessRunner` when a second consumer arrives. |
| 6 | Verification is a `HearingDemoPipeline` ObservableObject + a Hearing section in `ContentView` with `NSOpenPanel`. | Mirrors `DemoScanPipeline`/`ContentView` Vision-side convention; sandbox-clean via existing `files.user-selected.read-only` entitlement. |

## 3. File Layout

```
falsoai-lens/
├── Pipelines/Hearing/
│   ├── Inference/                            ← NEW
│   │   ├── TranscriptionEngine.swift         ← protocol
│   │   └── WhisperCppEngine.swift            ← actor, conforms
│   ├── Models/
│   │   ├── TranscriptionMode.swift           ← NEW
│   │   ├── TranscriptionResult.swift         ← NEW
│   │   ├── TranscriptSegment.swift           ← NEW
│   │   └── WhisperEngineError.swift          ← NEW
│   └── Services/
│       └── HearingDemoPipeline.swift         ← NEW (ObservableObject)
├── ContentView.swift                         ← edit: add Hearing demo section
└── Dependencies/Hearing/
    └── HearingDependencies.swift             ← edit: resource constants

BundledResources/                             ← NEW top-level (NOT under sync'd group)
├── Bin/whisper-cli                           (static binary, ~5 MB, gitignored)
└── Models/ggml-base.bin                      (~148 MB, gitignored)

scripts/
└── build-whisper-cli.sh                      ← NEW

docs/superpowers/specs/
└── 2026-05-06-whisper-inference-layer-design.md  ← this document
```

`BundledResources/` is deliberately a sibling of `falsoai-lens/`, not inside it. Placing it inside the file-system-synchronized group root would invite Xcode to misclassify the binary and the model. The name intentionally avoids `Resources/` to prevent confusion with the bundle's own `Contents/Resources/` directory; once dragged in as a folder reference, the .app contains the path `Contents/Resources/BundledResources/Bin/whisper-cli`. Adding the folder to the target is a one-time manual Xcode step (Section 6.3).

`BundledResources/Bin/whisper-cli`, `BundledResources/Models/`, and `.build/whisper.cpp/` are added to `.gitignore`. The build script is the source of truth for the binary; the model is downloaded once via `whisper.cpp/models/download-ggml-model.sh base`.

## 4. Components and Public Contracts

### 4.1 `TranscriptionMode`

```swift
enum TranscriptionMode: Sendable, Equatable {
    case transcribeOriginalLanguage
    case translateToEnglish
}
```

### 4.2 `TranscriptSegment`

```swift
struct TranscriptSegment: Sendable, Equatable {
    let startTime: TimeInterval?
    let endTime: TimeInterval?
    let text: String
}
```

### 4.3 `TranscriptionResult`

```swift
struct TranscriptionResult: Sendable, Equatable {
    let text: String
    let segments: [TranscriptSegment]
    let language: String?
    let duration: TimeInterval?
}
```

### 4.4 `WhisperEngineError`

```swift
enum WhisperEngineError: LocalizedError, Equatable {
    case missingExecutable
    case missingModel
    case audioFileNotFound(URL)
    case audioFileEmpty(URL)
    case processFailed(exitCode: Int32, stderr: String)
    case invalidJSONOutput(String)

    var errorDescription: String? { ... }
    var recoverySuggestion: String? { ... }
}
```

Each case carries enough context for both UI and logs:

- `missingExecutable.recoverySuggestion`: "Run `bash scripts/build-whisper-cli.sh` and rebuild the app."
- `missingModel.recoverySuggestion`: "Download `ggml-base.bin` (run `.build/whisper.cpp/models/download-ggml-model.sh base`) and place it at `BundledResources/Models/ggml-base.bin`, then rebuild the app."
- `processFailed`: includes captured stderr (truncated to a sane length in `errorDescription`, full in logs).
- `invalidJSONOutput`: includes a short excerpt of the unparseable bytes.

### 4.5 `TranscriptionEngine` protocol

```swift
protocol TranscriptionEngine: Sendable {
    func transcribe(
        audioFile: URL,
        mode: TranscriptionMode
    ) async throws -> TranscriptionResult
}
```

### 4.6 `WhisperCppEngine`

```swift
actor WhisperCppEngine: TranscriptionEngine {
    init(
        executableURL: URL? = nil,                 // nil → bundled
        modelURL: URL? = nil,                      // nil → bundled
        deletesJSONSidecarOnSuccess: Bool = true   // false in debug
    ) throws

    func transcribe(
        audioFile: URL,
        mode: TranscriptionMode
    ) async throws -> TranscriptionResult
}
```

`init` resolves bundled defaults via `Bundle.main.url(forResource:withExtension:subdirectory:)` and throws `.missingExecutable` / `.missingModel` synchronously so callers fail fast at construction.

### 4.7 `HearingDemoPipeline`

```swift
@MainActor
final class HearingDemoPipeline: ObservableObject {
    @Published private(set) var latestResult: TranscriptionResult?
    @Published private(set) var isTranscribing: Bool = false
    @Published private(set) var lastSelectedFileURL: URL?
    @Published private(set) var lastInferenceDurationSeconds: Double?
    @Published private(set) var errorMessage: String?

    init(engine: TranscriptionEngine? = nil)       // nil → tries WhisperCppEngine()

    func transcribe(fileURL: URL, mode: TranscriptionMode) async
}
```

Construction tolerates a missing engine (`nil` engine when `WhisperCppEngine.init` throws) by setting `errorMessage` and disabling the Transcribe button — so the app still launches even if the binary or model wasn't bundled (useful first-run state).

## 5. Process Invocation and JSON Parsing

### 5.1 Command line

```
<bundled whisper-cli>
    -m <bundled ggml-base.bin>
    -f <input audio file>
    -oj                      # writes <input>.json next to the input
    -nt                      # no inline timestamps in stdout
    [-tr]                    # only when mode == .translateToEnglish
```

### 5.2 Lifecycle inside `WhisperCppEngine.transcribe(...)`

1. Validate `audioFile` exists and is non-empty (throw `.audioFileNotFound` / `.audioFileEmpty`).
2. Build a `Process` with `executableURL = whisper-cli` and the args above.
3. Wire `Pipe`s for stdout and stderr; drain both asynchronously into `Data` buffers via `FileHandle.readabilityHandler`. Both pipes must be drained — letting either fill blocks `whisper-cli`.
4. Bridge `process.terminationHandler` to a `withCheckedContinuation` so the call site `await`s exit.
5. On non-zero `terminationStatus`: throw `.processFailed(exitCode:, stderr:)` with the captured stderr.
6. On success: read `<audioFile>.json`, decode with `JSONDecoder` into internal `Codable` types modeled on whisper.cpp's JSON schema:
   ```json
   {
     "result":        { "language": "es" },
     "transcription": [ { "timestamps": { "from": "00:00:00,000",
                                          "to":   "00:00:02,500" },
                          "text": " Hola, esto es una prueba." } ]
   }
   ```
   Convert `from`/`to` HH:MM:SS,mmm strings to `TimeInterval` seconds; map to `[TranscriptSegment]`. whisper.cpp's segment `text` typically includes a leading space, so compute the top-level `text` by concatenating segment texts verbatim and applying a single `trimmingCharacters(in: .whitespacesAndNewlines)` on the result — this preserves whisper's intended spacing without introducing double spaces. Compute `duration` as the last segment's `endTime` (nil-safe; `nil` if `segments` is empty).
7. Delete the JSON sidecar unless `deletesJSONSidecarOnSuccess == false`.
8. Return `TranscriptionResult`.

Actor isolation serializes concurrent calls so we don't launch parallel `whisper-cli` processes — that would thrash CPU/Metal on a single-engine MacBook. (When the audio capture path lands and chunks queue up, this is the correct backpressure.)

## 6. Bundling and Build

### 6.1 `scripts/build-whisper-cli.sh`

```bash
#!/usr/bin/env bash
# Builds a self-contained whisper-cli (no homebrew dylibs) into BundledResources/Bin/.
# Idempotent: skips work if BundledResources/Bin/whisper-cli already exists.

set -euo pipefail
WHISPER_VERSION="${WHISPER_VERSION:-v1.8.4}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="$REPO_ROOT/.build/whisper.cpp"
DEST="$REPO_ROOT/BundledResources/Bin/whisper-cli"

mkdir -p "$REPO_ROOT/BundledResources/Bin"
[ -d "$BUILD_DIR" ] || git clone --depth 1 --branch "$WHISPER_VERSION" \
  https://github.com/ggerganov/whisper.cpp.git "$BUILD_DIR"

cmake -S "$BUILD_DIR" -B "$BUILD_DIR/build" \
  -DBUILD_SHARED_LIBS=OFF \
  -DGGML_METAL_EMBED_LIBRARY=ON \
  -DWHISPER_BUILD_EXAMPLES=ON \
  -DWHISPER_BUILD_TESTS=OFF \
  -DCMAKE_BUILD_TYPE=Release
cmake --build "$BUILD_DIR/build" --config Release --target whisper-cli -j

cp "$BUILD_DIR/build/bin/whisper-cli" "$DEST"
chmod +x "$DEST"

if otool -L "$DEST" | grep -E "@rpath|/opt/" >/dev/null; then
  echo "ERROR: non-system dylib deps remain in $DEST" >&2
  otool -L "$DEST" >&2
  exit 1
fi
echo "✅ Built $DEST"
```

### 6.2 Model download

One-time, manually:

```bash
bash .build/whisper.cpp/models/download-ggml-model.sh base
mv .build/whisper.cpp/models/ggml-base.bin BundledResources/Models/ggml-base.bin
```

This is documented in the implementation plan as a prerequisite step rather than scripted, because `download-ggml-model.sh` does network I/O and we don't want it firing on every rebuild.

### 6.3 Xcode target wiring (one-time manual step)

1. In the project navigator, drag `BundledResources/` into the project. Choose **"Create folder references"** (blue folder icon), target = `falsoai-lens`. Xcode populates the **Copy Bundle Resources** build phase automatically. The folder reference preserves structure inside the .app, so the binary lands at `Contents/Resources/BundledResources/Bin/whisper-cli` and the model at `Contents/Resources/BundledResources/Models/ggml-base.bin`.
2. Add a **Run Script build phase** *after* "Copy Bundle Resources":
   ```bash
   if [ -f "$CODESIGNING_FOLDER_PATH/Contents/Resources/BundledResources/Bin/whisper-cli" ]; then
     codesign --force --options runtime \
       --sign "$EXPANDED_CODE_SIGN_IDENTITY" \
       "$CODESIGNING_FOLDER_PATH/Contents/Resources/BundledResources/Bin/whisper-cli"
   fi
   ```
3. Confirm build phase ordering: Copy Bundle Resources → Run Script (codesign) → standard signing/embed phases.

This is the **only** project.pbxproj change in the plan. CLAUDE.md's "do not edit project.pbxproj" rule applies to registering Swift source files (where the file-system-synchronized group makes the edit unnecessary); resources and run-script phases must be added through the UI.

### 6.4 `.gitignore` additions

```
BundledResources/Bin/
BundledResources/Models/
.build/whisper.cpp/
```

## 7. Concurrency, Logging, Error Handling

- `WhisperCppEngine` is an **actor**, mirroring the shape of `AudioNormalizer`. One transcription per engine instance at a time.
- `HearingDemoPipeline` is `@MainActor final class ObservableObject`, mirroring `DemoScanPipeline`. UI bindings stay on main; `await engine.transcribe(...)` hops to actor isolation automatically.
- Logging: `os.Logger` with subsystem `Bundle.main.bundleIdentifier ?? "com.falsoai.FalsoaiLens"`, categories:
  - `WhisperEngine` — process spawn args (path, mode, flags), exit code, durations, JSON sidecar size, error details.
  - `HearingDemo` — file selection, mode toggles, transcription start/end, duration.
- Match the existing structured-log style: `key=value` pairs joined with ` | `, `.public` privacy for non-PII fields, `.private` for any user audio paths.
- `WhisperCppEngine` reuses the static `errorLogDescription(for:)` pattern from the Vision services for structured `Process` error logging.

## 8. UI

### 8.1 ContentView Hearing section

Added below the existing Vision demo section:

```
┌─────────────────────────────────────────────┐
│ Live Audio (Hearing) Demo                   │
│                                             │
│ [Pick WAV File]  Mode: ⦿ Original ○ English │
│ [Transcribe]                                │
│                                             │
│ Selected: chunk-0001.wav (5.0 s)            │
│ Inference: 1.42 s                           │
│ Language: es                                │
│                                             │
│ ┌─ Transcript ────────────────────────────┐ │
│ │ Hola, esto es una prueba del sistema.  │ │
│ └────────────────────────────────────────┘ │
│                                             │
│ ┌─ Segments ──────────────────────────────┐ │
│ │ [00:00.00 → 00:02.50]  Hola, esto es…  │ │
│ │ [00:02.50 → 00:05.00]  …una prueba…    │ │
│ └────────────────────────────────────────┘ │
└─────────────────────────────────────────────┘
```

- File picker uses `NSOpenPanel` with `allowedContentTypes = [.wav, .audio]`. The existing `com.apple.security.files.user-selected.read-only` entitlement covers user-picked files.
- Mode selector is `Picker(selection:)` with `.segmented` style.
- Transcribe button is `.disabled(pipeline.isTranscribing || pipeline.lastSelectedFileURL == nil)`.
- Errors: `pipeline.errorMessage` rendered below the controls in red, mirroring the Vision section's `errorMessage` treatment.

### 8.2 Smoke-test fixture

```bash
say "Hello world. This is a Whisper inference smoke test." -o /tmp/sample.aiff
afconvert -f WAVE -d LEI16@16000 -c 1 /tmp/sample.aiff /tmp/sample.wav
```

Translation mode fixture (for verification):

```bash
say -v Mónica "Hola, esto es una prueba." -o /tmp/sample-es.aiff
afconvert -f WAVE -d LEI16@16000 -c 1 /tmp/sample-es.aiff /tmp/sample-es.wav
```

## 9. Verification Protocol

Implementation is complete when **all** of the following pass:

1. `bash scripts/build-whisper-cli.sh` produces `BundledResources/Bin/whisper-cli`; `otool -L` shows only `/usr/lib/*` dependencies (no `@rpath`, no `/opt/`).
2. `BundledResources/Models/ggml-base.bin` exists.
3. `xcodebuild -project falsoai-lens.xcodeproj -scheme falsoai-lens -configuration Debug build` succeeds with no errors.
4. `codesign -dvv "<DerivedData>/.../falsoai-lens.app/Contents/Resources/BundledResources/Bin/whisper-cli"` reports a valid Apple Development signature (not ad-hoc).
5. App launches cleanly. The Hearing section renders, "Pick WAV File" opens an `NSOpenPanel`, picking the English fixture WAV produces a non-empty transcript matching "Hello world..." in `<2 s` of inference time, and the JSON sidecar at `<input>.json` is cleaned up.
6. Switching mode to "English (translate)" and picking the Spanish fixture WAV produces an English transcript.
7. With no model bundled (manual test: rename `ggml-base.bin`), the app still launches, the Transcribe button is disabled, and `pipeline.errorMessage` shows the `.missingModel` recovery suggestion.

## 10. Out of Scope

Explicitly **not** in this spec; tracked for follow-up plans:

- Live microphone capture wiring — `AudioCaptureService` → `AudioBufferStore` → `AudioChunker` → `AudioNormalizer` → `WhisperCppEngine` end-to-end.
- Transcript Assembly Layer (suffix/prefix dedup across chunks).
- A test target. The verification protocol above is manual; adding XCTest is a separate plan.
- Replacing CLI invocation with a native `whisper.cpp` SwiftPM wrapper (Architecture doc Section 4.5 "Future Integration Strategy").
- VAD, diarization, summarization, RAG memory.

## 11. Open Risks

- **Xcode file-sync vs. manual resource registration.** Folder references (blue folders) outside the sync'd group should work, but if the bundled files don't appear in the built `.app`, fall back to dragging `BundledResources/` *inside* `falsoai-lens/` as a group and explicitly setting Target Membership per file. The implementation plan should document whichever resolution actually works.
- **Code-signing whisper-cli with the dev identity.** The Run Script phase assumes `EXPANDED_CODE_SIGN_IDENTITY` is set (it is for Apple Development signing) and that the dev cert has Hardened Runtime usage authorized. If `codesign` fails on the bundled binary, the plan will add a fallback that uses ad-hoc signing for local dev only and raises a clear warning.
- **whisper.cpp version drift.** `WHISPER_VERSION` is pinned in the build script. JSON schema changes upstream would break the parser; the implementation plan includes a unit-style fixture (a known JSON file checked into the repo) that exercises the parser independent of the binary.
