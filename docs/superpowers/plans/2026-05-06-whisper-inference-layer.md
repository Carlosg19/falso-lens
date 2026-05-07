# Whisper Inference Layer Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the Whisper Inference Layer — the unit that converts a 16 kHz mono PCM WAV file into transcribed (or English-translated) text — by bundling a self-contained `whisper-cli` and `ggml-base.bin` inside the .app, exposing a `TranscriptionEngine` protocol with a `WhisperCppEngine` actor implementation, and surfacing a `HearingDemoPipeline` + ContentView demo section for manual verification.

**Architecture:** A `whisper.cpp` static binary is built from source (no homebrew dylibs) into `BundledResources/Bin/whisper-cli`. It and `ggml-base.bin` are bundled via an Xcode folder reference and code-signed with the dev identity at app build time. `WhisperCppEngine` is an actor that resolves bundled resources via `Bundle.main`, copies sandbox-foreign input WAVs to a sandbox-private temp directory, runs `whisper-cli` with `-oj -of ... -nt [-tr]` via `Foundation.Process`, decodes the JSON sidecar into `TranscriptionResult`, and cleans up. `HearingDemoPipeline` orchestrates the user-picked-file path with security-scoped access; `ContentView` exposes the demo UI.

**Tech Stack:** Swift 5 / SwiftUI / Foundation `Process` / Swift `actor` / whisper.cpp v1.8.4 (built from source) / `os.Logger` / GRDB (existing, untouched) / SwiftData (existing, untouched).

**Spec:** [docs/superpowers/specs/2026-05-06-whisper-inference-layer-design.md](../specs/2026-05-06-whisper-inference-layer-design.md) (committed at `de21c07`).

**Note on TDD:** The project has no XCTest target ([CLAUDE.md](../../../CLAUDE.md) "Build / Run") and the spec deliberately keeps adding one out of scope ([§10](../specs/2026-05-06-whisper-inference-layer-design.md)). This plan adapts TDD discipline to the project's reality: each task ends with `xcodebuild ... build` succeeding (compiler-level "test" — surfaces type, signature, and import errors immediately) and a commit. The pure JSON-parsing logic (the part most worth unit-testing) gets a `#if DEBUG` fixture-driven smoke check that runs at engine init in debug builds.

**Note on sandbox:** The app is sandboxed with `com.apple.security.files.user-selected.read-only`. `whisper-cli` writes a JSON sidecar next to its input by default; we cannot write next to a user-picked file. The plan therefore (a) uses `whisper-cli`'s `-of` flag to redirect output, and (b) has `HearingDemoPipeline` copy the user-picked WAV into `NSTemporaryDirectory()` (sandbox-private, writable by both us and the inherited-sandbox child process) before calling the engine. This was an underspecified detail in the spec.

---

## File Structure

| Path | Action | Responsibility |
|---|---|---|
| `scripts/build-whisper-cli.sh` | Create | Reproducible static-binary build (clones whisper.cpp at pinned tag, runs CMake, copies output to `BundledResources/Bin/whisper-cli`, asserts no non-system dylib deps remain). |
| `BundledResources/Bin/whisper-cli` | Create (gitignored) | Static binary, ~5 MB, produced by the build script. |
| `BundledResources/Models/ggml-base.bin` | Create (gitignored) | ~148 MB multilingual Whisper base model. Manually downloaded once. |
| `falsoai-lens/Pipelines/Hearing/Models/TranscriptionMode.swift` | Create | `enum TranscriptionMode { transcribeOriginalLanguage, translateToEnglish }`. |
| `falsoai-lens/Pipelines/Hearing/Models/TranscriptSegment.swift` | Create | `struct TranscriptSegment` with optional start/end times + text. |
| `falsoai-lens/Pipelines/Hearing/Models/TranscriptionResult.swift` | Create | `struct TranscriptionResult` (text, segments, language, duration). |
| `falsoai-lens/Pipelines/Hearing/Models/WhisperEngineError.swift` | Create | `LocalizedError` enum: missingExecutable, missingModel, audioFileNotFound, audioFileEmpty, processFailed, invalidJSONOutput. |
| `falsoai-lens/Pipelines/Hearing/Inference/TranscriptionEngine.swift` | Create | Protocol with `transcribe(audioFile:mode:) async throws -> TranscriptionResult`. |
| `falsoai-lens/Pipelines/Hearing/Inference/WhisperCppEngine.swift` | Create | `actor WhisperCppEngine: TranscriptionEngine`. Owns the entire Process lifecycle and JSON parsing. |
| `falsoai-lens/Pipelines/Hearing/Services/HearingDemoPipeline.swift` | Create | `@MainActor final class HearingDemoPipeline: ObservableObject` orchestrator. Handles security-scoped access + temp copy. |
| `falsoai-lens/Pipelines/Hearing/Resources/whisper-fixture.json` | Create | Checked-in JSON fixture used by the parser smoke check. |
| `falsoai-lens/ContentView.swift` | Modify | Add Hearing demo section (file picker, mode selector, transcript/segment display). |
| `falsoai-lens/Dependencies/Hearing/HearingDependencies.swift` | Modify | Add bundled-resource path constants. |
| `.gitignore` | Modify | Add `BundledResources/Bin/`, `BundledResources/Models/`, `.build/whisper.cpp/`. |
| `falsoai-lens.xcodeproj/project.pbxproj` | Modify (via Xcode UI only) | Add `BundledResources/` as folder reference; add Run Script build phase to codesign the bundled binary. |

---

## Task 1: Static `whisper-cli` Binary

**Files:**
- Create: `scripts/build-whisper-cli.sh`
- Create: `BundledResources/Bin/whisper-cli` (build artifact)
- Modify: `.gitignore`

- [ ] **Step 1.1: Create `scripts/build-whisper-cli.sh`**

```bash
#!/usr/bin/env bash
# Builds a self-contained whisper-cli (no homebrew dylibs) into BundledResources/Bin/.
# Idempotent: regenerates only when version-pin changes or output is missing.

set -euo pipefail

WHISPER_VERSION="${WHISPER_VERSION:-v1.8.4}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="$REPO_ROOT/.build/whisper.cpp"
DEST="$REPO_ROOT/BundledResources/Bin/whisper-cli"

mkdir -p "$REPO_ROOT/BundledResources/Bin"

if [ ! -d "$BUILD_DIR" ]; then
    git clone --depth 1 --branch "$WHISPER_VERSION" \
        https://github.com/ggerganov/whisper.cpp.git "$BUILD_DIR"
fi

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

echo "✅ Built $DEST ($(du -h "$DEST" | cut -f1))"
```

- [ ] **Step 1.2: Make executable and run**

Run:
```bash
chmod +x scripts/build-whisper-cli.sh
bash scripts/build-whisper-cli.sh
```

Expected: builds for several minutes; final output `✅ Built .../BundledResources/Bin/whisper-cli (~5M or so)`.

- [ ] **Step 1.3: Verify dynamic deps are clean**

Run:
```bash
otool -L BundledResources/Bin/whisper-cli
```

Expected: only `/usr/lib/libc++.1.dylib` and `/usr/lib/libSystem.B.dylib` (system) — no `@rpath`, no `/opt/homebrew/...`.

- [ ] **Step 1.4: Update `.gitignore`**

Append the following block to the end of `.gitignore`:

```
# Whisper inference: build artifacts and bundled resources
.build/whisper.cpp/
BundledResources/Bin/
BundledResources/Models/
```

- [ ] **Step 1.5: Commit**

```bash
git add scripts/build-whisper-cli.sh .gitignore
git commit -m "build: add static whisper-cli build script (Whisper inference layer)"
```

---

## Task 2: Place the Whisper Model

**Files:**
- Create: `BundledResources/Models/ggml-base.bin` (gitignored, no commit)

- [ ] **Step 2.1: Reuse existing model if present**

Run:
```bash
ls -lh models/ggml-base.bin BundledResources/Models/ggml-base.bin 2>&1
```

Expected: existing model already at `models/ggml-base.bin`. If `BundledResources/Models/ggml-base.bin` does not exist:

```bash
mkdir -p BundledResources/Models
cp models/ggml-base.bin BundledResources/Models/ggml-base.bin
```

If you don't have `models/ggml-base.bin` either, run the upstream downloader instead:

```bash
mkdir -p BundledResources/Models
bash .build/whisper.cpp/models/download-ggml-model.sh base
mv .build/whisper.cpp/models/ggml-base.bin BundledResources/Models/ggml-base.bin
```

- [ ] **Step 2.2: Verify size**

Run:
```bash
ls -lh BundledResources/Models/ggml-base.bin
```

Expected: ~148 MB (multilingual base model).

- [ ] **Step 2.3: Smoke-test the binary against the model directly**

This catches model/binary version mismatch before we wire any Swift around it.

```bash
say "Hello world. This is a Whisper smoke test." -o /tmp/sample.aiff
afconvert -f WAVE -d LEI16@16000 -c 1 /tmp/sample.aiff /tmp/sample.wav
BundledResources/Bin/whisper-cli \
    -m BundledResources/Models/ggml-base.bin \
    -f /tmp/sample.wav \
    -oj -of /tmp/sample-result -nt
cat /tmp/sample-result.json | head -20
```

Expected: a JSON document containing a `transcription` array with at least one segment whose `text` contains "Hello world".

(No commit — model file is gitignored.)

---

## Task 3: Hearing Domain Types

**Files:**
- Create: `falsoai-lens/Pipelines/Hearing/Models/TranscriptionMode.swift`
- Create: `falsoai-lens/Pipelines/Hearing/Models/TranscriptSegment.swift`
- Create: `falsoai-lens/Pipelines/Hearing/Models/TranscriptionResult.swift`
- Create: `falsoai-lens/Pipelines/Hearing/Models/WhisperEngineError.swift`
- Create: `falsoai-lens/Pipelines/Hearing/Inference/TranscriptionEngine.swift`

- [ ] **Step 3.1: Create `TranscriptionMode.swift`**

```swift
import Foundation

enum TranscriptionMode: Sendable, Equatable, CaseIterable, Identifiable {
    case transcribeOriginalLanguage
    case translateToEnglish

    var id: Self { self }

    var displayName: String {
        switch self {
        case .transcribeOriginalLanguage:
            return "Original"
        case .translateToEnglish:
            return "English (translate)"
        }
    }
}
```

- [ ] **Step 3.2: Create `TranscriptSegment.swift`**

```swift
import Foundation

struct TranscriptSegment: Sendable, Equatable, Identifiable {
    let id: UUID
    let startTime: TimeInterval?
    let endTime: TimeInterval?
    let text: String

    init(
        id: UUID = UUID(),
        startTime: TimeInterval?,
        endTime: TimeInterval?,
        text: String
    ) {
        self.id = id
        self.startTime = startTime
        self.endTime = endTime
        self.text = text
    }
}
```

- [ ] **Step 3.3: Create `TranscriptionResult.swift`**

```swift
import Foundation

struct TranscriptionResult: Sendable, Equatable {
    let text: String
    let segments: [TranscriptSegment]
    let language: String?
    let duration: TimeInterval?
}
```

- [ ] **Step 3.4: Create `WhisperEngineError.swift`**

```swift
import Foundation

enum WhisperEngineError: LocalizedError, Equatable {
    case missingExecutable
    case missingModel
    case audioFileNotFound(URL)
    case audioFileEmpty(URL)
    case processFailed(exitCode: Int32, stderr: String)
    case invalidJSONOutput(String)

    var errorDescription: String? {
        switch self {
        case .missingExecutable:
            return "Bundled whisper-cli binary was not found inside the app."
        case .missingModel:
            return "Bundled Whisper model (ggml-base.bin) was not found inside the app."
        case let .audioFileNotFound(url):
            return "Audio file does not exist at \(url.path)."
        case let .audioFileEmpty(url):
            return "Audio file at \(url.path) is empty (0 bytes)."
        case let .processFailed(exitCode, stderr):
            let trimmed = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            let snippet = trimmed.count > 240 ? String(trimmed.prefix(240)) + "…" : trimmed
            return "whisper-cli exited with status \(exitCode). stderr: \(snippet.isEmpty ? "(empty)" : snippet)"
        case let .invalidJSONOutput(snippet):
            return "whisper-cli produced JSON output that could not be decoded. Excerpt: \(snippet)"
        }
    }

    var recoverySuggestion: String? {
        switch self {
        case .missingExecutable:
            return "Run `bash scripts/build-whisper-cli.sh` and rebuild the app."
        case .missingModel:
            return "Download `ggml-base.bin` (run `.build/whisper.cpp/models/download-ggml-model.sh base`) and place it at `BundledResources/Models/ggml-base.bin`, then rebuild the app."
        case .audioFileNotFound:
            return "Pick a WAV file that exists, or check that the audio capture pipeline produced a file."
        case .audioFileEmpty:
            return "The audio file has no content. Capture audio of at least 1 second before transcribing."
        case .processFailed:
            return "Check Console for the WhisperEngine category log for full stderr. If the error mentions an incompatible model, rebuild the binary or model."
        case .invalidJSONOutput:
            return "whisper.cpp may have changed its JSON schema. Pin the version in `scripts/build-whisper-cli.sh` and rebuild."
        }
    }
}
```

- [ ] **Step 3.5: Create `TranscriptionEngine.swift`**

```swift
import Foundation

protocol TranscriptionEngine: Sendable {
    func transcribe(
        audioFile: URL,
        mode: TranscriptionMode
    ) async throws -> TranscriptionResult
}
```

- [ ] **Step 3.6: Build to verify everything compiles**

Run:
```bash
xcodebuild -project falsoai-lens.xcodeproj -scheme falsoai-lens -configuration Debug build 2>&1 | grep -E "error:|warning:" | head -20
```

Expected: no `error:` lines. Trailing line is `** BUILD SUCCEEDED **` (verify by piping to `tail` if needed).

- [ ] **Step 3.7: Commit**

```bash
git add falsoai-lens/Pipelines/Hearing/Models/TranscriptionMode.swift \
        falsoai-lens/Pipelines/Hearing/Models/TranscriptSegment.swift \
        falsoai-lens/Pipelines/Hearing/Models/TranscriptionResult.swift \
        falsoai-lens/Pipelines/Hearing/Models/WhisperEngineError.swift \
        falsoai-lens/Pipelines/Hearing/Inference/TranscriptionEngine.swift
git commit -m "feat(hearing): add TranscriptionEngine protocol and result/error types"
```

---

## Task 4: `WhisperCppEngine` — Initialization and Resource Resolution

**Files:**
- Create: `falsoai-lens/Pipelines/Hearing/Inference/WhisperCppEngine.swift`

- [ ] **Step 4.1: Create the engine with resource-resolving init only**

```swift
import Foundation
import OSLog

actor WhisperCppEngine: TranscriptionEngine {
    private let executableURL: URL
    private let modelURL: URL
    private let deletesJSONSidecarOnSuccess: Bool

    private nonisolated static let bundledExecutableSubdirectory = "BundledResources/Bin"
    private nonisolated static let bundledModelSubdirectory = "BundledResources/Models"
    private nonisolated static let bundledExecutableName = "whisper-cli"
    private nonisolated static let bundledModelResourceName = "ggml-base"
    private nonisolated static let bundledModelResourceExtension = "bin"

    private nonisolated static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.falsoai.FalsoaiLens",
        category: "WhisperEngine"
    )

    init(
        executableURL: URL? = nil,
        modelURL: URL? = nil,
        deletesJSONSidecarOnSuccess: Bool = true
    ) throws {
        let resolvedExecutableURL = try executableURL ?? Self.resolveBundledExecutable()
        let resolvedModelURL = try modelURL ?? Self.resolveBundledModel()

        guard FileManager.default.isExecutableFile(atPath: resolvedExecutableURL.path) else {
            Self.logger.error("Bundled whisper-cli is not executable path=\(resolvedExecutableURL.path, privacy: .public)")
            throw WhisperEngineError.missingExecutable
        }

        self.executableURL = resolvedExecutableURL
        self.modelURL = resolvedModelURL
        self.deletesJSONSidecarOnSuccess = deletesJSONSidecarOnSuccess

        Self.logger.info(
            "WhisperCppEngine initialized executable=\(resolvedExecutableURL.path, privacy: .public), model=\(resolvedModelURL.path, privacy: .public), deletesSidecarOnSuccess=\(deletesJSONSidecarOnSuccess, privacy: .public)"
        )
    }

    func transcribe(
        audioFile: URL,
        mode: TranscriptionMode
    ) async throws -> TranscriptionResult {
        // Implementation lands in Task 5 (Process invocation) and Task 6 (JSON parsing).
        // Stub for now so the type compiles.
        _ = audioFile
        _ = mode
        throw WhisperEngineError.processFailed(exitCode: -1, stderr: "transcribe not yet implemented")
    }

    private nonisolated static func resolveBundledExecutable() throws -> URL {
        if let url = Bundle.main.url(
            forResource: bundledExecutableName,
            withExtension: nil,
            subdirectory: bundledExecutableSubdirectory
        ) {
            return url
        }
        logger.error("Could not find bundled whisper-cli at \(bundledExecutableSubdirectory, privacy: .public)/\(bundledExecutableName, privacy: .public)")
        throw WhisperEngineError.missingExecutable
    }

    private nonisolated static func resolveBundledModel() throws -> URL {
        if let url = Bundle.main.url(
            forResource: bundledModelResourceName,
            withExtension: bundledModelResourceExtension,
            subdirectory: bundledModelSubdirectory
        ) {
            return url
        }
        logger.error("Could not find bundled \(bundledModelResourceName, privacy: .public).\(bundledModelResourceExtension, privacy: .public) at \(bundledModelSubdirectory, privacy: .public)")
        throw WhisperEngineError.missingModel
    }
}
```

- [ ] **Step 4.2: Build**

Run:
```bash
xcodebuild -project falsoai-lens.xcodeproj -scheme falsoai-lens -configuration Debug build 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **`. (The Bundle lookups will return nil at runtime until Task 9 wires the resources, but the **compile** is clean.)

- [ ] **Step 4.3: Commit**

```bash
git add falsoai-lens/Pipelines/Hearing/Inference/WhisperCppEngine.swift
git commit -m "feat(hearing): add WhisperCppEngine actor scaffolding with bundled-resource resolution"
```

---

## Task 5: `WhisperCppEngine` — Process Invocation

**Files:**
- Modify: `falsoai-lens/Pipelines/Hearing/Inference/WhisperCppEngine.swift`

- [ ] **Step 5.1: Replace the stubbed `transcribe(...)` and add private helpers**

Open `falsoai-lens/Pipelines/Hearing/Inference/WhisperCppEngine.swift` and replace the body of `transcribe(audioFile:mode:)` (the throw-stub from Task 4) with the real Process-driven implementation. Also append the private helpers at the end of the actor.

Replace this block:

```swift
    func transcribe(
        audioFile: URL,
        mode: TranscriptionMode
    ) async throws -> TranscriptionResult {
        // Implementation lands in Task 5 (Process invocation) and Task 6 (JSON parsing).
        // Stub for now so the type compiles.
        _ = audioFile
        _ = mode
        throw WhisperEngineError.processFailed(exitCode: -1, stderr: "transcribe not yet implemented")
    }
```

with:

```swift
    func transcribe(
        audioFile: URL,
        mode: TranscriptionMode
    ) async throws -> TranscriptionResult {
        try Self.validateAudioFile(audioFile)

        let outputPrefix = NSTemporaryDirectory()
            + "whisper-output-\(UUID().uuidString)"
        let jsonURL = URL(fileURLWithPath: outputPrefix + ".json")
        defer {
            if deletesJSONSidecarOnSuccess {
                try? FileManager.default.removeItem(at: jsonURL)
            }
        }

        let result = try await runWhisper(
            audioFile: audioFile,
            mode: mode,
            outputPrefix: outputPrefix
        )

        guard result.exitCode == 0 else {
            Self.logger.error(
                "whisper-cli failed exitCode=\(result.exitCode, privacy: .public), stderrLength=\(result.stderr.count, privacy: .public)"
            )
            throw WhisperEngineError.processFailed(
                exitCode: result.exitCode,
                stderr: result.stderr
            )
        }

        // Task 6 will replace this stub with a real JSON parse + map.
        Self.logger.info(
            "whisper-cli completed jsonSidecar=\(jsonURL.path, privacy: .public), stdoutLength=\(result.stdout.count, privacy: .public)"
        )
        return TranscriptionResult(
            text: result.stdout.trimmingCharacters(in: .whitespacesAndNewlines),
            segments: [],
            language: nil,
            duration: nil
        )
    }

    private struct ProcessInvocationResult {
        let exitCode: Int32
        let stderr: String
        let stdout: String
    }

    private static func validateAudioFile(_ audioFile: URL) throws {
        let path = audioFile.path
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: path) else {
            throw WhisperEngineError.audioFileNotFound(audioFile)
        }
        let attributes = try fileManager.attributesOfItem(atPath: path)
        let size = (attributes[.size] as? NSNumber)?.intValue ?? 0
        guard size > 0 else {
            throw WhisperEngineError.audioFileEmpty(audioFile)
        }
    }

    private func runWhisper(
        audioFile: URL,
        mode: TranscriptionMode,
        outputPrefix: String
    ) async throws -> ProcessInvocationResult {
        var arguments: [String] = [
            "-m", modelURL.path,
            "-f", audioFile.path,
            "-oj",
            "-of", outputPrefix,
            "-nt",
        ]
        if mode == .translateToEnglish {
            arguments.append("-tr")
        }

        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let stdoutBuffer = AsyncDataAccumulator()
        let stderrBuffer = AsyncDataAccumulator()

        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty {
                stdoutBuffer.append(data)
            }
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty {
                stderrBuffer.append(data)
            }
        }

        Self.logger.info(
            "whisper-cli launching mode=\(String(describing: mode), privacy: .public), arguments=\(arguments.joined(separator: " "), privacy: .public)"
        )
        let start = Date()

        do {
            try process.run()
        } catch {
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            Self.logger.error("Failed to launch whisper-cli: \(String(describing: error), privacy: .public)")
            throw WhisperEngineError.processFailed(
                exitCode: -1,
                stderr: "Could not launch whisper-cli: \(error.localizedDescription)"
            )
        }

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            process.terminationHandler = { _ in
                continuation.resume()
            }
        }

        // Drain any remaining data after exit.
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil
        let trailingStdout = stdoutPipe.fileHandleForReading.availableData
        if !trailingStdout.isEmpty {
            stdoutBuffer.append(trailingStdout)
        }
        let trailingStderr = stderrPipe.fileHandleForReading.availableData
        if !trailingStderr.isEmpty {
            stderrBuffer.append(trailingStderr)
        }

        let elapsed = Date().timeIntervalSince(start)
        Self.logger.info(
            "whisper-cli exit status=\(process.terminationStatus, privacy: .public), elapsedSeconds=\(elapsed, privacy: .public), stdoutBytes=\(stdoutBuffer.byteCount, privacy: .public), stderrBytes=\(stderrBuffer.byteCount, privacy: .public)"
        )

        return ProcessInvocationResult(
            exitCode: process.terminationStatus,
            stderr: stderrBuffer.makeString(),
            stdout: stdoutBuffer.makeString()
        )
    }
}

private final class AsyncDataAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    var byteCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return data.count
    }

    func append(_ chunk: Data) {
        lock.lock()
        data.append(chunk)
        lock.unlock()
    }

    func makeString() -> String {
        lock.lock()
        defer { lock.unlock() }
        return String(data: data, encoding: .utf8) ?? ""
    }
}
```

- [ ] **Step 5.2: Build**

Run:
```bash
xcodebuild -project falsoai-lens.xcodeproj -scheme falsoai-lens -configuration Debug build 2>&1 | grep -E "error:|warning:" | head -20
```

Expected: no `error:` lines.

- [ ] **Step 5.3: Commit**

```bash
git add falsoai-lens/Pipelines/Hearing/Inference/WhisperCppEngine.swift
git commit -m "feat(hearing): wire WhisperCppEngine to whisper-cli via Process"
```

---

## Task 6: `WhisperCppEngine` — JSON Sidecar Parsing

**Files:**
- Modify: `falsoai-lens/Pipelines/Hearing/Inference/WhisperCppEngine.swift`
- Create: `falsoai-lens/Pipelines/Hearing/Resources/whisper-fixture.json`

- [ ] **Step 6.1: Add the parser smoke-test fixture**

Create `falsoai-lens/Pipelines/Hearing/Resources/whisper-fixture.json` with this content (a representative whisper.cpp v1.8.x JSON output):

```json
{
  "result": {
    "language": "en"
  },
  "transcription": [
    {
      "timestamps": {
        "from": "00:00:00,000",
        "to": "00:00:02,500"
      },
      "offsets": {
        "from": 0,
        "to": 2500
      },
      "text": " Hello world."
    },
    {
      "timestamps": {
        "from": "00:00:02,500",
        "to": "00:00:05,000"
      },
      "offsets": {
        "from": 2500,
        "to": 5000
      },
      "text": " This is a Whisper smoke test."
    }
  ]
}
```

This file is **inside** `falsoai-lens/` (synced group), so it gets bundled as a resource automatically.

- [ ] **Step 6.2: Replace the JSON-parsing stub in `WhisperCppEngine.transcribe(...)`**

In `falsoai-lens/Pipelines/Hearing/Inference/WhisperCppEngine.swift`, replace this block from Task 5:

```swift
        // Task 6 will replace this stub with a real JSON parse + map.
        Self.logger.info(
            "whisper-cli completed jsonSidecar=\(jsonURL.path, privacy: .public), stdoutLength=\(result.stdout.count, privacy: .public)"
        )
        return TranscriptionResult(
            text: result.stdout.trimmingCharacters(in: .whitespacesAndNewlines),
            segments: [],
            language: nil,
            duration: nil
        )
```

with:

```swift
        Self.logger.info(
            "whisper-cli completed jsonSidecar=\(jsonURL.path, privacy: .public), stdoutLength=\(result.stdout.count, privacy: .public)"
        )

        let jsonData: Data
        do {
            jsonData = try Data(contentsOf: jsonURL)
        } catch {
            Self.logger.error(
                "Could not read whisper JSON sidecar at \(jsonURL.path, privacy: .public): \(String(describing: error), privacy: .public)"
            )
            throw WhisperEngineError.invalidJSONOutput("could not read \(jsonURL.lastPathComponent): \(error.localizedDescription)")
        }

        return try Self.decodeTranscriptionResult(from: jsonData)
    }

    nonisolated static func decodeTranscriptionResult(from data: Data) throws -> TranscriptionResult {
        let decoder = JSONDecoder()
        let raw: RawWhisperOutput
        do {
            raw = try decoder.decode(RawWhisperOutput.self, from: data)
        } catch {
            let snippet = (String(data: data.prefix(160), encoding: .utf8) ?? "<non-utf8 bytes>")
                .replacingOccurrences(of: "\n", with: " ")
            logger.error(
                "Failed to decode whisper JSON: \(String(describing: error), privacy: .public). snippet=\(snippet, privacy: .public)"
            )
            throw WhisperEngineError.invalidJSONOutput(snippet)
        }

        let segments: [TranscriptSegment] = raw.transcription.map { rawSegment in
            TranscriptSegment(
                startTime: parseWhisperTimestamp(rawSegment.timestamps.from),
                endTime: parseWhisperTimestamp(rawSegment.timestamps.to),
                text: rawSegment.text
            )
        }

        let combinedText = raw.transcription
            .map(\.text)
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let duration = segments.last?.endTime
        let language = raw.result?.language

        return TranscriptionResult(
            text: combinedText,
            segments: segments,
            language: language,
            duration: duration
        )
    }

    nonisolated static func parseWhisperTimestamp(_ raw: String) -> TimeInterval? {
        // Whisper.cpp emits "HH:MM:SS,mmm" — comma separator, not period.
        let components = raw.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
        guard components.count == 3 else { return nil }
        guard let hours = Int(components[0]), let minutes = Int(components[1]) else { return nil }
        let secondsPart = components[2].replacingOccurrences(of: ",", with: ".")
        guard let seconds = Double(secondsPart) else { return nil }
        return TimeInterval(hours * 3600) + TimeInterval(minutes * 60) + seconds
    }

    private struct RawWhisperOutput: Decodable {
        struct Result: Decodable {
            let language: String?
        }
        struct Transcription: Decodable {
            let timestamps: Timestamps
            let text: String
        }
        struct Timestamps: Decodable {
            let from: String
            let to: String
        }
        let result: Result?
        let transcription: [Transcription]
```

(Note: the closing `}` for `RawWhisperOutput` is on the next line — see the next step's full file to confirm.)

- [ ] **Step 6.3: Add the closing brace and a `#if DEBUG` smoke check**

Append, immediately after the `RawWhisperOutput` struct's body:

```swift
    }

    #if DEBUG
    nonisolated static func runParserSmokeCheck() {
        guard let url = Bundle.main.url(
            forResource: "whisper-fixture",
            withExtension: "json"
        ) else {
            logger.error("Parser smoke check skipped: whisper-fixture.json not bundled")
            return
        }
        do {
            let data = try Data(contentsOf: url)
            let result = try decodeTranscriptionResult(from: data)
            assert(
                result.text.contains("Hello world"),
                "Parser smoke check: expected text to contain 'Hello world', got '\(result.text)'"
            )
            assert(
                result.segments.count == 2,
                "Parser smoke check: expected 2 segments, got \(result.segments.count)"
            )
            assert(
                result.language == "en",
                "Parser smoke check: expected language 'en', got '\(result.language ?? "nil")'"
            )
            assert(
                result.duration == 5.0,
                "Parser smoke check: expected duration 5.0, got \(String(describing: result.duration))"
            )
            logger.info("✅ Parser smoke check passed text=\"\(result.text, privacy: .public)\", segments=\(result.segments.count, privacy: .public), language=\(result.language ?? "nil", privacy: .public), duration=\(result.duration ?? -1, privacy: .public)")
        } catch {
            assertionFailure("Parser smoke check failed: \(error)")
        }
    }
    #endif
```

The `runParserSmokeCheck()` will be invoked from `HearingDemoPipeline.init` in Task 7, so any parser regression surfaces the moment the app launches a debug build.

- [ ] **Step 6.4: Build**

Run:
```bash
xcodebuild -project falsoai-lens.xcodeproj -scheme falsoai-lens -configuration Debug build 2>&1 | grep -E "error:|warning:" | head -20
```

Expected: no `error:` lines.

- [ ] **Step 6.5: Commit**

```bash
git add falsoai-lens/Pipelines/Hearing/Inference/WhisperCppEngine.swift \
        falsoai-lens/Pipelines/Hearing/Resources/whisper-fixture.json
git commit -m "feat(hearing): parse whisper-cli JSON output into TranscriptionResult"
```

---

## Task 7: `HearingDemoPipeline` Orchestrator

**Files:**
- Create: `falsoai-lens/Pipelines/Hearing/Services/HearingDemoPipeline.swift`

- [ ] **Step 7.1: Create the orchestrator**

```swift
import Foundation
import OSLog
import SwiftUI

@MainActor
final class HearingDemoPipeline: ObservableObject {
    @Published private(set) var latestResult: TranscriptionResult?
    @Published private(set) var isTranscribing: Bool = false
    @Published private(set) var lastSelectedFileURL: URL?
    @Published private(set) var lastInferenceDurationSeconds: Double?
    @Published private(set) var errorMessage: String?

    private let engine: TranscriptionEngine?
    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.falsoai.FalsoaiLens",
        category: "HearingDemo"
    )

    init(engine: TranscriptionEngine? = nil) {
        if let engine {
            self.engine = engine
        } else {
            do {
                self.engine = try WhisperCppEngine()
            } catch let error as WhisperEngineError {
                self.engine = nil
                let message = error.errorDescription ?? "Whisper engine unavailable"
                let suggestion = error.recoverySuggestion ?? ""
                self.errorMessage = suggestion.isEmpty ? message : "\(message) \(suggestion)"
                logger.error("HearingDemoPipeline could not construct engine: \(message, privacy: .public). \(suggestion, privacy: .public)")
            } catch {
                self.engine = nil
                self.errorMessage = "Whisper engine unavailable: \(error.localizedDescription)"
                logger.error("HearingDemoPipeline failed to construct engine: \(String(describing: error), privacy: .public)")
            }
        }

        #if DEBUG
        WhisperCppEngine.runParserSmokeCheck()
        #endif
    }

    var isEngineAvailable: Bool {
        engine != nil
    }

    func setSelectedFile(_ url: URL) {
        lastSelectedFileURL = url
        latestResult = nil
        lastInferenceDurationSeconds = nil
        errorMessage = nil
        logger.info("HearingDemo file selected path=\(url.path, privacy: .private)")
    }

    func transcribe(mode: TranscriptionMode) async {
        guard let engine else {
            errorMessage = errorMessage ?? "Whisper engine is not available."
            return
        }
        guard let userURL = lastSelectedFileURL else {
            errorMessage = "Pick a WAV file first."
            return
        }

        isTranscribing = true
        errorMessage = nil
        defer { isTranscribing = false }

        let didStartAccess = userURL.startAccessingSecurityScopedResource()
        defer {
            if didStartAccess {
                userURL.stopAccessingSecurityScopedResource()
            }
        }

        let workingURL: URL
        do {
            workingURL = try Self.copyToSandboxTemporary(userURL)
        } catch {
            errorMessage = "Could not stage audio file for transcription: \(error.localizedDescription)"
            logger.error("HearingDemo copy failed: \(String(describing: error), privacy: .public)")
            return
        }
        defer {
            try? FileManager.default.removeItem(at: workingURL)
        }

        let started = Date()
        do {
            let result = try await engine.transcribe(audioFile: workingURL, mode: mode)
            let elapsed = Date().timeIntervalSince(started)
            latestResult = result
            lastInferenceDurationSeconds = elapsed
            logger.info(
                "HearingDemo transcription completed mode=\(String(describing: mode), privacy: .public), elapsedSeconds=\(elapsed, privacy: .public), characters=\(result.text.count, privacy: .public), segments=\(result.segments.count, privacy: .public), language=\(result.language ?? "nil", privacy: .public)"
            )
        } catch let error as WhisperEngineError {
            let message = error.errorDescription ?? "Transcription failed."
            let suggestion = error.recoverySuggestion ?? ""
            errorMessage = suggestion.isEmpty ? message : "\(message) \(suggestion)"
            logger.error("HearingDemo transcription failed: \(message, privacy: .public)")
        } catch {
            errorMessage = "Transcription failed: \(error.localizedDescription)"
            logger.error("HearingDemo transcription failed (unexpected): \(String(describing: error), privacy: .public)")
        }
    }

    private static func copyToSandboxTemporary(_ source: URL) throws -> URL {
        let workingDirectory = URL(
            fileURLWithPath: NSTemporaryDirectory(),
            isDirectory: true
        ).appendingPathComponent("hearing-demo", isDirectory: true)
        try FileManager.default.createDirectory(
            at: workingDirectory,
            withIntermediateDirectories: true
        )

        let suffix = source.pathExtension.isEmpty ? "wav" : source.pathExtension
        let destination = workingDirectory
            .appendingPathComponent("input-\(UUID().uuidString)")
            .appendingPathExtension(suffix)
        try FileManager.default.copyItem(at: source, to: destination)
        return destination
    }
}
```

- [ ] **Step 7.2: Build**

Run:
```bash
xcodebuild -project falsoai-lens.xcodeproj -scheme falsoai-lens -configuration Debug build 2>&1 | grep -E "error:|warning:" | head -20
```

Expected: no `error:` lines.

- [ ] **Step 7.3: Commit**

```bash
git add falsoai-lens/Pipelines/Hearing/Services/HearingDemoPipeline.swift
git commit -m "feat(hearing): add HearingDemoPipeline orchestrator with sandbox-safe staging"
```

---

## Task 8: Update `HearingDependencies`

**Files:**
- Modify: `falsoai-lens/Dependencies/Hearing/HearingDependencies.swift`

- [ ] **Step 8.1: Replace the file content**

Replace the entire content of `falsoai-lens/Dependencies/Hearing/HearingDependencies.swift` with:

```swift
import AVFoundation

enum HearingDependencies {
    static let captureEngineType = AVAudioEngine.self
    static let microphoneMediaType = AVMediaType.audio
    static let bundledExecutableSubdirectory = "BundledResources/Bin"
    static let bundledModelSubdirectory = "BundledResources/Models"
    static let bundledExecutableName = "whisper-cli"
    static let bundledModelResourceName = "ggml-base"
    static let bundledModelResourceExtension = "bin"
}
```

These constants are **also** referenced inside `WhisperCppEngine` as private static fields. The duplication is intentional — `HearingDependencies` is the project-wide registry of audio-pipeline-related types and constants ([DependencyImports.swift:14](../../../falsoai-lens/Dependencies/DependencyImports.swift#L14) reads `HearingDependencies.captureEngineType`); the engine maintains its own copies to keep the inference type self-contained and to avoid forcing every test/replacement engine to import the dependencies module.

- [ ] **Step 8.2: Build**

Run:
```bash
xcodebuild -project falsoai-lens.xcodeproj -scheme falsoai-lens -configuration Debug build 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 8.3: Commit**

```bash
git add falsoai-lens/Dependencies/Hearing/HearingDependencies.swift
git commit -m "chore(hearing): register Whisper bundled-resource constants in HearingDependencies"
```

---

## Task 9: Xcode Project — Folder Reference + Codesign Run Script

This is the only project.pbxproj change in the plan. It MUST be done via the Xcode UI; the file-system-synchronized group does not handle binary resources or build phases. CLAUDE.md's "do not edit project.pbxproj" rule is about Swift sources — Xcode is the right tool here.

**Files:**
- Modify (via Xcode UI): `falsoai-lens.xcodeproj/project.pbxproj`

- [ ] **Step 9.1: Add `BundledResources/` as a folder reference**

1. Open the project: `open falsoai-lens.xcodeproj`.
2. In the project navigator (left sidebar), right-click the **falsoai-lens** project (top-level blue icon) → **Add Files to "falsoai-lens"…**
3. Navigate to and select the `BundledResources/` folder at the repo root.
4. In the dialog, set:
   - **Action:** Create folder references (NOT "Create groups"). Folder reference shows as a blue folder icon. Group shows as yellow.
   - **Add to targets:** ✅ falsoai-lens
5. Click **Add**.
6. Verify in the project navigator: `BundledResources` appears as a **blue** folder. Expand it; you should see `Bin/whisper-cli` and `Models/ggml-base.bin`.
7. Verify the target: select the **falsoai-lens** target → **Build Phases** → **Copy Bundle Resources**. The list should now include `BundledResources` (single entry — folder references appear as a single line).

- [ ] **Step 9.2: Add the codesign Run Script build phase**

1. With the **falsoai-lens** target still selected → **Build Phases** → click the **+** button at the top → **New Run Script Phase**.
2. Rename the new phase from "Run Script" to: `Re-sign bundled whisper-cli`.
3. Drag the new phase so it sits **after** "Copy Bundle Resources" and **before** any signing-related phase Xcode may have added (e.g., "Embed Frameworks"). The default order of new run-script phases is "at the end", which is also fine — what matters is that it runs after the bundle resources are copied.
4. Set the script content to:

```bash
set -euo pipefail
TARGET_BIN="$CODESIGNING_FOLDER_PATH/Contents/Resources/BundledResources/Bin/whisper-cli"
if [ -f "$TARGET_BIN" ]; then
    /usr/bin/codesign \
        --force \
        --options runtime \
        --sign "${EXPANDED_CODE_SIGN_IDENTITY:-${CODE_SIGN_IDENTITY:--}}" \
        "$TARGET_BIN"
    echo "✅ Re-signed $TARGET_BIN"
else
    echo "⚠️  $TARGET_BIN not found — skipping re-sign (debug builds before BundledResources/ is populated)"
fi
```

5. Leave **Show environment variables in build log** checked, **Run script only when installing** unchecked (we want it on every build), and the input/output file lists empty.

- [ ] **Step 9.3: Build via xcodebuild**

```bash
xcodebuild -project falsoai-lens.xcodeproj -scheme falsoai-lens -configuration Debug build 2>&1 | tail -20
```

Expected: `** BUILD SUCCEEDED **`. The build log should include the `✅ Re-signed ...` line from the script.

If you see "BundledResources/Bin/whisper-cli not found" or the binary doesn't appear in the .app: switch to the spec's [§11 fallback](../specs/2026-05-06-whisper-inference-layer-design.md#11-open-risks): drag `BundledResources/` *inside* `falsoai-lens/` as a group with explicit per-file Target Membership. Document whichever resolution you took in this same task's commit message.

- [ ] **Step 9.4: Verify the bundled binary is present and signed**

```bash
APP_PATH="$(xcodebuild -project falsoai-lens.xcodeproj -scheme falsoai-lens -configuration Debug -showBuildSettings 2>/dev/null | grep -m1 '^\s*BUILT_PRODUCTS_DIR' | awk '{print $3}')/falsoai-lens.app"
ls -la "$APP_PATH/Contents/Resources/BundledResources/Bin/whisper-cli" "$APP_PATH/Contents/Resources/BundledResources/Models/ggml-base.bin"
codesign -dvv "$APP_PATH/Contents/Resources/BundledResources/Bin/whisper-cli" 2>&1 | head -10
```

Expected:
- Both file paths exist and have non-zero sizes.
- The `codesign -dvv` output reports a real Apple Development team identifier (NOT `flags=0x2(adhoc)` and NOT `TeamIdentifier=not set`).

- [ ] **Step 9.5: Commit the project.pbxproj changes**

```bash
git add falsoai-lens.xcodeproj/project.pbxproj
git commit -m "build: bundle whisper-cli + ggml-base.bin and re-sign at app build time"
```

---

## Task 10: ContentView Hearing Demo Section

**Files:**
- Modify: `falsoai-lens/ContentView.swift`

- [ ] **Step 10.1: Add the pipeline as a `@StateObject`**

In `falsoai-lens/ContentView.swift`, find the existing line:

```swift
    @StateObject private var pipeline = DemoScanPipeline()
```

and add the following line directly under it:

```swift
    @StateObject private var hearing = HearingDemoPipeline()
    @State private var hearingMode: TranscriptionMode = .transcribeOriginalLanguage
```

- [ ] **Step 10.2: Add the demo section helper**

At the bottom of the `ContentView` struct (after the existing `resultView(_:)` private helper), add:

```swift
    private var hearingDemoSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Live Audio (Hearing) Demo")
                .font(.title2)

            HStack {
                Button {
                    pickHearingFile()
                } label: {
                    Label("Pick WAV File", systemImage: "doc.badge.plus")
                }

                Picker("Mode", selection: $hearingMode) {
                    ForEach(TranscriptionMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 280)
            }

            HStack {
                Button {
                    Task { await hearing.transcribe(mode: hearingMode) }
                } label: {
                    Label(
                        hearing.isTranscribing ? "Transcribing…" : "Transcribe",
                        systemImage: "waveform.badge.mic"
                    )
                }
                .disabled(
                    hearing.isTranscribing
                        || hearing.lastSelectedFileURL == nil
                        || !hearing.isEngineAvailable
                )

                if let url = hearing.lastSelectedFileURL {
                    Text("Selected: \(url.lastPathComponent)")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            if let elapsed = hearing.lastInferenceDurationSeconds {
                Text(String(format: "Inference: %.2f s", elapsed))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let language = hearing.latestResult?.language {
                Text("Language: \(language)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let result = hearing.latestResult, !result.text.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Transcript")
                        .font(.headline)
                    ScrollView {
                        Text(result.text)
                            .font(.body)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                    }
                    .frame(minHeight: 100, maxHeight: 200)
                    .background(Color(nsColor: .textBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                }

                if !result.segments.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Segments")
                            .font(.headline)
                        ForEach(result.segments) { segment in
                            HStack(alignment: .top, spacing: 8) {
                                Text(formatRange(start: segment.startTime, end: segment.endTime))
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                Text(segment.text.trimmingCharacters(in: .whitespaces))
                                    .font(.callout)
                            }
                        }
                    }
                }
            }

            if let hearingError = hearing.errorMessage {
                Text(hearingError)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
        }
        .padding()
        .background(.thinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func pickHearingFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.wav, .audio]
        panel.title = "Pick a 16 kHz mono WAV file"
        if panel.runModal() == .OK, let url = panel.url {
            hearing.setSelectedFile(url)
        }
    }

    private func formatRange(start: TimeInterval?, end: TimeInterval?) -> String {
        let startText = formatTimestamp(start) ?? "--:--.--"
        let endText = formatTimestamp(end) ?? "--:--.--"
        return "[\(startText) → \(endText)]"
    }

    private func formatTimestamp(_ seconds: TimeInterval?) -> String? {
        guard let seconds else { return nil }
        let minutes = Int(seconds) / 60
        let remaining = seconds - TimeInterval(minutes * 60)
        return String(format: "%02d:%05.2f", minutes, remaining)
    }
```

You'll need an additional import at the top of `ContentView.swift` for `NSOpenPanel` and `UTType.wav` / `.audio`. Update the imports block (currently `import SwiftData` / `import SwiftUI`) to:

```swift
import AppKit
import SwiftData
import SwiftUI
import UniformTypeIdentifiers
```

- [ ] **Step 10.3: Render the section in `body`**

In `ContentView.body`'s `detail:` closure, find the trailing block:

```swift
                if let result = pipeline.latestResult {
                    resultView(result)
                }

                if pipeline.lastOCRText.isEmpty {
                    Spacer()
                }
```

and insert a `hearingDemoSection` line between the two `if` statements, so the result reads:

```swift
                if let result = pipeline.latestResult {
                    resultView(result)
                }

                hearingDemoSection

                if pipeline.lastOCRText.isEmpty {
                    Spacer()
                }
```

- [ ] **Step 10.4: Build**

Run:
```bash
xcodebuild -project falsoai-lens.xcodeproj -scheme falsoai-lens -configuration Debug build 2>&1 | grep -E "error:|warning:" | head -20
```

Expected: no `error:` lines.

- [ ] **Step 10.5: Launch the app from Xcode and visually confirm**

```bash
open falsoai-lens.xcodeproj
```

Then in Xcode press ⌘R (Run). Confirm:
- The app launches without crashing.
- The detail pane shows the existing Vision demo controls AND a new "Live Audio (Hearing) Demo" panel below them.
- The "Transcribe" button is **disabled** (no file selected yet).
- The Console (View → Debug Area → Show Debug Area) shows a `✅ Parser smoke check passed` log line from category `WhisperEngine`.

- [ ] **Step 10.6: Commit**

```bash
git add falsoai-lens/ContentView.swift
git commit -m "feat(hearing): add ContentView demo section for Whisper inference"
```

---

## Task 11: End-to-End Smoke Test (the spec's §9 verification protocol)

**Files:**
- (none modified — verification only)

These steps mirror [the spec's §9 Verification Protocol](../specs/2026-05-06-whisper-inference-layer-design.md). Implementation is not complete until all of them pass.

- [ ] **Step 11.1: Confirm static-binary cleanliness**

Run:
```bash
otool -L BundledResources/Bin/whisper-cli | grep -vE "^/usr/lib/(libc\+\+\.1|libSystem\.B)" | grep -v "^BundledResources" || echo "✅ no non-system deps"
```

Expected: `✅ no non-system deps`.

- [ ] **Step 11.2: Confirm model is in place**

Run:
```bash
test -s BundledResources/Models/ggml-base.bin && echo "✅ model present" || echo "❌ model missing"
```

Expected: `✅ model present`.

- [ ] **Step 11.3: Confirm xcodebuild succeeds**

Run:
```bash
xcodebuild -project falsoai-lens.xcodeproj -scheme falsoai-lens -configuration Debug build 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 11.4: Confirm the bundled binary is signed with the dev identity**

Run:
```bash
APP_PATH="$(xcodebuild -project falsoai-lens.xcodeproj -scheme falsoai-lens -configuration Debug -showBuildSettings 2>/dev/null | grep -m1 '^\s*BUILT_PRODUCTS_DIR' | awk '{print $3}')/falsoai-lens.app"
codesign -dvv "$APP_PATH/Contents/Resources/BundledResources/Bin/whisper-cli" 2>&1 | grep -E "TeamIdentifier|Signature"
```

Expected:
- `Signature=...` (NOT `Signature=adhoc`)
- `TeamIdentifier=<dev team>` (NOT `not set`)

- [ ] **Step 11.5: English transcription smoke test (in-app)**

Generate the fixture once:

```bash
say "Hello world. This is a Whisper inference smoke test." -o /tmp/sample.aiff
afconvert -f WAVE -d LEI16@16000 -c 1 /tmp/sample.aiff /tmp/sample.wav
```

Then in Xcode (⌘R):
1. Click **Pick WAV File** → choose `/tmp/sample.wav`.
2. Mode: **Original**.
3. Click **Transcribe**.

Expected:
- Within ~2 seconds, the transcript area shows text containing "Hello world".
- The **Inference** label shows a positive number (typically `0.5`–`2.0` seconds).
- The **Language** label shows `en`.
- At least one segment renders with timestamps.

- [ ] **Step 11.6: Spanish-to-English translation smoke test (in-app)**

Generate the Spanish fixture:

```bash
say -v Mónica "Hola, esto es una prueba." -o /tmp/sample-es.aiff
afconvert -f WAVE -d LEI16@16000 -c 1 /tmp/sample-es.aiff /tmp/sample-es.wav
```

In the running app:
1. Click **Pick WAV File** → choose `/tmp/sample-es.wav`.
2. Mode: **English (translate)**.
3. Click **Transcribe**.

Expected: the transcript is English (e.g., "Hello, this is a test.") — NOT Spanish text — and language reports `es` (the detected source language).

- [ ] **Step 11.7: `.missingModel` graceful failure smoke test**

Quit the app. Then:

```bash
mv BundledResources/Models/ggml-base.bin BundledResources/Models/ggml-base.bin.bak
```

Rebuild + relaunch the app from Xcode (⌘R). Expected:
- The app launches cleanly (no crash).
- The Hearing demo section renders, but the **Transcribe** button is disabled.
- An error message under the controls reads something close to: *"Bundled Whisper model (ggml-base.bin) was not found inside the app. Download `ggml-base.bin` (...)…"*

Restore the model:

```bash
mv BundledResources/Models/ggml-base.bin.bak BundledResources/Models/ggml-base.bin
```

- [ ] **Step 11.8: Confirm temp-file hygiene**

After running steps 11.5–11.6, check that no temp files leaked:

```bash
ls "$TMPDIR/hearing-demo/" 2>&1 | head -5 || echo "(directory empty or absent)"
ls "$TMPDIR/whisper-output-"* 2>&1 | head -5 || echo "(no whisper-output sidecars)"
```

Expected: both lists are empty (or "no such file" / "directory empty").

- [ ] **Step 11.9: Commit any remediation made during verification**

If steps 11.1–11.8 surfaced bugs and you fixed them inline, commit the fixes now with a focused message. If everything passed cleanly, no commit is needed for this task.

```bash
git status -s
# If there are changes:
# git add <fixed files>
# git commit -m "fix(hearing): <what you fixed during verification>"
```

---

## Self-Review Notes

- **Spec coverage:** All sections of the spec map to a task — Section 3 file layout → Tasks 3/4/8/10; §4 contracts → Tasks 3/4/5/6/7; §5 process+JSON → Tasks 5/6; §6 bundling → Tasks 1/2/9; §7 concurrency/logging → embedded throughout (engine actor, MainActor pipeline, `os.Logger`); §8 UI → Task 10; §9 verification protocol → Task 11; §10 out-of-scope items are not implemented (explicitly so); §11 risks are addressed by Task 1.3 (otool check), Task 9.3/Step 11.4 (signing verification), Task 6 (parser smoke check guards against whisper.cpp version drift in DEBUG).
- **Type consistency:** `TranscriptionMode`, `TranscriptionResult`, `TranscriptSegment`, `WhisperEngineError`, `TranscriptionEngine`, `WhisperCppEngine`, `HearingDemoPipeline` — names match between spec and plan. The orchestrator-side method `setSelectedFile(_:)` and `transcribe(mode:)` are introduced for the UI binding; the engine-side `transcribe(audioFile:mode:)` matches the protocol.
- **Underspecified detail surfaced:** Sandbox + `whisper-cli` JSON sidecar location → resolved with `-of <NSTemporaryDirectory>/whisper-output-<uuid>` and `HearingDemoPipeline.copyToSandboxTemporary(_:)`. Documented in the plan preamble and Task 7.
- **No placeholders.** Every step contains the actual code or the exact command. The only "do this in the next task" forward references are explicit and the next task replaces the stub with the real implementation in the same file.
