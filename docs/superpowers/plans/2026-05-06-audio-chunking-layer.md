# Audio Chunking Layer Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the Hearing pipeline's Chunking Layer: a small `AudioChunker` that applies the MVP 5-second chunk and 1-second overlap policy to the existing rolling audio buffer.

**Architecture:** Keep chunking as policy and coordination, not storage. `AudioBufferStore` continues to own mutable sample storage and overlap mechanics; `AudioChunker` validates chunking settings, appends captured buffers into the store, drains every ready `BufferedAudioChunk`, and clears state when a recording session ends. Do not implement normalization, WAV writing, Whisper execution, transcript deduplication, or SwiftUI wiring in this plan.

**Tech Stack:** Swift, Foundation, Swift actors, Sendable value types, existing `CapturedAudioBuffer`, `BufferedAudioChunk`, and `AudioBufferStore`.

---

## Assumptions

- The current doc source of truth is `docs/Live Audio Transcriber Architecture.md`, especially section `4.3 Chunking Layer`.
- `AudioBufferStore.extractChunk(duration:retainingOverlap:)` already preserves overlap samples by removing only `chunkDuration - overlapDuration` worth of frames after each extraction.
- This layer should emit raw `BufferedAudioChunk` values, not file-backed `AudioChunk` values. File-backed chunks belong after normalization and WAV writing.
- The MVP chunking policy is exactly 5 seconds with 1 second of overlap.
- There is no test target configured yet, so verification is build-based until a test target exists.

## File Structure

- Create `falsoai-lens/Pipelines/Hearing/Models/AudioChunkingConfiguration.swift`
  - Defines the chunk duration and overlap duration used by `AudioChunker`.
  - Provides the MVP default: 5 seconds with 1 second overlap.
  - Validates that duration is positive and overlap is non-negative and shorter than the chunk duration.
- Create `falsoai-lens/Pipelines/Hearing/Services/AudioChunker.swift`
  - Actor that coordinates chunking against an `AudioBufferStore`.
  - Appends `CapturedAudioBuffer` values and returns all chunks that became ready.
  - Exposes explicit draining for callers that already appended audio elsewhere.
  - Exposes available duration and clear operations for session orchestration.
- Modify `docs/Live Audio Transcriber Architecture.md`
  - Add an implementation boundary note under `4.3 Chunking Layer`.

No Xcode project file edits are needed because `falsoai-lens/` is a file-system synchronized group.

---

### Task 1: Add Chunking Configuration

**Files:**
- Create: `falsoai-lens/Pipelines/Hearing/Models/AudioChunkingConfiguration.swift`

- [x] **Step 1: Create the configuration model**

Create `falsoai-lens/Pipelines/Hearing/Models/AudioChunkingConfiguration.swift`:

```swift
import Foundation

enum AudioChunkerError: LocalizedError, Equatable {
    case invalidConfiguration(chunkDuration: TimeInterval, overlapDuration: TimeInterval)

    var errorDescription: String? {
        switch self {
        case let .invalidConfiguration(chunkDuration, overlapDuration):
            return "Audio chunking configuration is invalid. Chunk duration \(chunkDuration)s must be greater than overlap \(overlapDuration)s, and overlap cannot be negative."
        }
    }
}

struct AudioChunkingConfiguration: Sendable, Equatable {
    var chunkDuration: TimeInterval
    var overlapDuration: TimeInterval

    nonisolated static let mvp = AudioChunkingConfiguration(
        chunkDuration: 5,
        overlapDuration: 1
    )

    nonisolated func validate() throws {
        guard chunkDuration > 0, overlapDuration >= 0, overlapDuration < chunkDuration else {
            throw AudioChunkerError.invalidConfiguration(
                chunkDuration: chunkDuration,
                overlapDuration: overlapDuration
            )
        }
    }
}
```

- [x] **Step 2: Build-check the configuration**

Run:

```bash
xcodebuild -project falsoai-lens.xcodeproj -scheme falsoai-lens -configuration Debug build
```

Expected: build succeeds.

---

### Task 2: Add Audio Chunker Actor

**Files:**
- Create: `falsoai-lens/Pipelines/Hearing/Services/AudioChunker.swift`

- [x] **Step 1: Create the chunker actor**

Create `falsoai-lens/Pipelines/Hearing/Services/AudioChunker.swift`:

```swift
import Foundation

actor AudioChunker {
    private let bufferStore: AudioBufferStore
    private let configuration: AudioChunkingConfiguration

    init(
        bufferStore: AudioBufferStore = AudioBufferStore(),
        configuration: AudioChunkingConfiguration = .mvp
    ) throws {
        try configuration.validate()
        self.bufferStore = bufferStore
        self.configuration = configuration
    }

    func append(_ buffer: CapturedAudioBuffer) async throws -> [BufferedAudioChunk] {
        try await bufferStore.append(buffer)
        return try await drainAvailableChunks()
    }

    func drainAvailableChunks() async throws -> [BufferedAudioChunk] {
        var chunks: [BufferedAudioChunk] = []

        while let chunk = try await nextChunk() {
            chunks.append(chunk)
        }

        return chunks
    }

    func nextChunk() async throws -> BufferedAudioChunk? {
        try await bufferStore.extractChunk(
            duration: configuration.chunkDuration,
            retainingOverlap: configuration.overlapDuration
        )
    }

    func availableDuration() async -> TimeInterval {
        await bufferStore.availableDuration
    }

    func clear() async {
        await bufferStore.clear()
    }
}
```

- [x] **Step 2: Build-check the chunker**

Run:

```bash
xcodebuild -project falsoai-lens.xcodeproj -scheme falsoai-lens -configuration Debug build
```

Expected: build succeeds.

---

### Task 3: Add Chunking Layer Boundary To Architecture Doc

**Files:**
- Modify: `docs/Live Audio Transcriber Architecture.md`

- [x] **Step 1: Add an implementation note under `4.3 Chunking Layer`**

Add this note after the chunk size tradeoff section and before `4.4 Audio Normalization Layer`:

```markdown
### Implementation Boundary

The app implementation keeps this layer focused on chunking policy and buffer coordination. It uses the MVP 5-second chunk duration with 1 second of overlap, appends incoming `CapturedAudioBuffer` values to `AudioBufferStore`, drains every ready `BufferedAudioChunk`, and clears chunking state when recording stops. It does not resample audio, convert channels, write WAV files, invoke Whisper, assemble transcripts, or update SwiftUI directly.
```

- [x] **Step 2: Validate markdown whitespace**

Run:

```bash
git diff --check -- 'docs/Live Audio Transcriber Architecture.md'
```

Expected: no output and exit code 0.

---

### Task 4: Final Verification

**Files:**
- Verify all files touched in this plan.

- [x] **Step 1: Check formatting whitespace**

Run:

```bash
git diff --check -- falsoai-lens/Pipelines/Hearing 'docs/Live Audio Transcriber Architecture.md' docs/superpowers/plans/2026-05-06-audio-chunking-layer.md
```

Expected: no output and exit code 0.

- [x] **Step 2: Build the app**

Run:

```bash
xcodebuild -project falsoai-lens.xcodeproj -scheme falsoai-lens -configuration Debug build
```

Expected: build succeeds.

- [x] **Step 3: Confirm scope stayed within Chunking Layer**

Run:

```bash
git status --short
```

Expected new or modified files for this layer:

```text
docs/Live Audio Transcriber Architecture.md
docs/superpowers/plans/2026-05-06-audio-chunking-layer.md
falsoai-lens/Pipelines/Hearing/Models/AudioChunkingConfiguration.swift
falsoai-lens/Pipelines/Hearing/Services/AudioChunker.swift
```

Existing unrelated workspace changes may also appear. Do not revert them. If normalization, WAV writing, Whisper, transcript, or UI files appear because of this task, stop and remove those changes from this layer.

---

## Notes For Execution

- This plan intentionally does not wire `AudioCaptureService` or `AudioChunker` into `ContentView`.
- `AudioChunker.append(_:)` returns an array because one incoming capture buffer can make zero, one, or multiple chunks ready depending on buffer size and backlog.
- `AudioChunker.nextChunk()` exists for callers that want manual polling, while `append(_:)` is the normal live-capture path.
- The next layer can take each `BufferedAudioChunk` and normalize it to the Whisper target format: 16 kHz mono PCM WAV.
