# Concurrent Separated Audio Chunks Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Emit microphone and computer audio chunks for the same time window together, then transcribe both sources concurrently while preserving source-specific transcript lanes.

**Architecture:** Replace the current "drain whichever source is ready" behavior with synchronized chunk windows keyed by sequence number and source. `MixedAudioBufferStore` should return a `SeparatedAudioChunkBatch` containing the microphone and/or computer chunk for one logical time window; the live pipeline should transcribe chunks within each batch concurrently and apply results in a deterministic microphone-first order.

**Tech Stack:** Swift, Swift concurrency (`async let` / task groups), actors, ScreenCaptureKit, AVAudioEngine, existing `WhisperCppEngine`.

---

## File Structure

- Modify: `falsoai-lens/Pipelines/Hearing/Models/SeparatedAudioChunkBatch.swift`
  - New model that groups chunks by logical window.
- Modify: `falsoai-lens/Pipelines/Hearing/Services/MixedAudioBufferStore.swift`
  - Emit synchronized chunk batches instead of a flat chunk list.
- Modify: `falsoai-lens/Pipelines/Hearing/Services/LiveMixedAudioTranscriptionPipeline.swift`
  - Process each batch concurrently and commit transcript updates in stable source order.
- Modify: `falsoai-lens/Pipelines/Hearing/Services/HearingDemoPipeline.swift`
  - Update debug smoke checks if signatures change.
- Optional Modify: `docs/Live Audio Transcriber Architecture.md`
  - Document synchronized source-window behavior after implementation.

## Design Rules

- Microphone and computer chunks must keep independent PCM samples.
- A batch is identified by source-local sequence number for now. Because both sources use the same chunk duration and overlap, sequence `N` is the logical "same window" for both.
- If only one source is available after a short grace window, emit a single-source batch so silence or unavailable system audio cannot block microphone transcription forever.
- Transcription for chunks inside one batch should happen concurrently.
- Transcript state mutation remains `@MainActor`.
- Commit order is deterministic: microphone result first, computer result second. This lets microphone own duplicate spoken utterances.

---

### Task 1: Add Batch Model

**Files:**
- Create: `falsoai-lens/Pipelines/Hearing/Models/SeparatedAudioChunkBatch.swift`

- [ ] **Step 1: Create the model**

Create `falsoai-lens/Pipelines/Hearing/Models/SeparatedAudioChunkBatch.swift`:

```swift
import Foundation

struct SeparatedAudioChunkBatch: Sendable, Equatable {
    let sequenceNumber: Int
    let microphone: BufferedAudioChunk?
    let computer: BufferedAudioChunk?

    var chunksInProcessingOrder: [BufferedAudioChunk] {
        [microphone, computer].compactMap { $0 }
    }

    var isEmpty: Bool {
        microphone == nil && computer == nil
    }
}
```

- [ ] **Step 2: Build**

Run:

```bash
xcodebuild -project falsoai-lens.xcodeproj -scheme falsoai-lens -configuration Debug build
```

Expected: `BUILD SUCCEEDED`.

---

### Task 2: Emit Synchronized Chunk Batches

**Files:**
- Modify: `falsoai-lens/Pipelines/Hearing/Services/MixedAudioBufferStore.swift`

- [ ] **Step 1: Change public return types**

Update:

```swift
func append(_ packet: CapturedAudioPacket) throws -> [SeparatedAudioChunkBatch]

func drainAvailableChunks() throws -> [SeparatedAudioChunkBatch]
```

- [ ] **Step 2: Implement batch draining**

Replace the current `drainAvailableChunks()` body with:

```swift
func drainAvailableChunks() throws -> [SeparatedAudioChunkBatch] {
    var batches: [SeparatedAudioChunkBatch] = []

    while true {
        let microphoneReady = hasChunkReady(in: microphoneState)
        let computerReady = hasChunkReady(in: computerState)

        if !microphoneReady, !computerReady {
            break
        }

        let nextSequenceNumber = min(
            microphoneReady ? microphoneState.nextChunkSequenceNumber : Int.max,
            computerReady ? computerState.nextChunkSequenceNumber : Int.max
        )

        let microphoneChunk = microphoneReady && microphoneState.nextChunkSequenceNumber == nextSequenceNumber
            ? try nextChunk(for: .microphone)
            : nil

        let computerChunk = computerReady && computerState.nextChunkSequenceNumber == nextSequenceNumber
            ? try nextChunk(for: .computer)
            : nil

        let batch = SeparatedAudioChunkBatch(
            sequenceNumber: nextSequenceNumber,
            microphone: microphoneChunk,
            computer: computerChunk
        )

        if batch.isEmpty {
            break
        }

        batches.append(batch)
    }

    return batches
}
```

- [ ] **Step 3: Keep helper methods**

Ensure these helpers exist in `MixedAudioBufferStore`:

```swift
private var chunkFrameCount: Int {
    max(1, Int((configuration.chunkDuration * configuration.sampleRate).rounded(.toNearestOrAwayFromZero)))
}

private func hasChunkReady(in state: SourceBufferState) -> Bool {
    state.samples.count >= chunkFrameCount
}
```

- [ ] **Step 4: Build**

Run:

```bash
xcodebuild -project falsoai-lens.xcodeproj -scheme falsoai-lens -configuration Debug build
```

Expected: Build fails only at call sites that still expect `[BufferedAudioChunk]`.

---

### Task 3: Process Each Batch Concurrently

**Files:**
- Modify: `falsoai-lens/Pipelines/Hearing/Services/LiveMixedAudioTranscriptionPipeline.swift`

- [ ] **Step 1: Add a result wrapper**

Inside `LiveMixedAudioTranscriptionPipeline`, add:

```swift
private struct SourceTranscriptionOutput: Sendable {
    let source: CapturedAudioSource
    let result: TranscriptionResult
    let elapsed: Double
}
```

- [ ] **Step 2: Replace batch loop at capture call site**

In `start(mode:)`, replace the chunk loop with:

```swift
let batches = try await mixer.append(packet)
for batch in batches {
    if Task.isCancelled { break }
    await self?.transcribe(batch: batch, normalizer: normalizer, engine: engine, mode: mode)
}
```

- [ ] **Step 3: Add concurrent batch transcription**

Add:

```swift
private func transcribe(
    batch: SeparatedAudioChunkBatch,
    normalizer: AudioNormalizer,
    engine: TranscriptionEngine,
    mode: TranscriptionMode
) async {
    isProcessingChunk = true
    statusText = "Transcribing recent separated audio..."

    var outputs: [SourceTranscriptionOutput] = []

    await withTaskGroup(of: SourceTranscriptionOutput?.self) { group in
        for chunk in batch.chunksInProcessingOrder {
            group.addTask {
                await Self.transcribeOutput(
                    chunk: chunk,
                    normalizer: normalizer,
                    engine: engine,
                    mode: mode
                )
            }
        }

        for await output in group {
            if let output {
                outputs.append(output)
            }
        }
    }

    for source in [CapturedAudioSource.microphone, .computer] {
        for output in outputs where output.source == source {
            append(result: output.result, source: output.source, elapsed: output.elapsed)
        }
    }

    isProcessingChunk = false
    if isRunning, errorMessage == nil {
        statusText = "Listening to separated computer and microphone audio..."
    }
}
```

- [ ] **Step 4: Extract nonisolated chunk transcription**

Add:

```swift
private nonisolated static func transcribeOutput(
    chunk: BufferedAudioChunk,
    normalizer: AudioNormalizer,
    engine: TranscriptionEngine,
    mode: TranscriptionMode
) async -> SourceTranscriptionOutput? {
    let started = Date()

    do {
        let normalizedChunk = try await normalizer.normalizeToTemporaryWAV(chunk)
        guard let fileURL = normalizedChunk.fileURL else {
            throw AudioNormalizationError.invalidChunkFormat(
                sampleRate: normalizedChunk.sampleRate,
                channelCount: normalizedChunk.channelCount,
                frameCount: normalizedChunk.frameCount
            )
        }
        defer {
            try? FileManager.default.removeItem(at: fileURL)
        }

        let result = try await engine.transcribe(audioFile: fileURL, mode: mode)
        return SourceTranscriptionOutput(
            source: chunk.source,
            result: result,
            elapsed: Date().timeIntervalSince(started)
        )
    } catch {
        return SourceTranscriptionOutput(
            source: chunk.source,
            result: TranscriptionResult(text: "", segments: [], language: nil, duration: 0),
            elapsed: Date().timeIntervalSince(started)
        )
    }
}
```

- [ ] **Step 5: Remove or keep old single-chunk method**

If no longer used, remove:

```swift
private func transcribe(
    chunk: BufferedAudioChunk,
    normalizer: AudioNormalizer,
    engine: TranscriptionEngine,
    mode: TranscriptionMode
) async
```

- [ ] **Step 6: Build**

Run:

```bash
xcodebuild -project falsoai-lens.xcodeproj -scheme falsoai-lens -configuration Debug build
```

Expected: `BUILD SUCCEEDED`.

---

### Task 4: Improve Error Visibility For Concurrent Tasks

**Files:**
- Modify: `falsoai-lens/Pipelines/Hearing/Services/LiveMixedAudioTranscriptionPipeline.swift`

- [ ] **Step 1: Add optional error field**

Change `SourceTranscriptionOutput` to:

```swift
private struct SourceTranscriptionOutput: Sendable {
    let source: CapturedAudioSource
    let result: TranscriptionResult
    let elapsed: Double
    let errorMessage: String?
}
```

- [ ] **Step 2: Return errors from worker**

In `transcribeOutput`, replace the `catch` return with:

```swift
return SourceTranscriptionOutput(
    source: chunk.source,
    result: TranscriptionResult(text: "", segments: [], language: nil, duration: 0),
    elapsed: Date().timeIntervalSince(started),
    errorMessage: Self.userFacingMessage(for: error)
)
```

Set successful outputs to `errorMessage: nil`.

- [ ] **Step 3: Apply errors on main actor**

Before appending outputs:

```swift
let errors = outputs.compactMap(\.errorMessage)
if let firstError = errors.first {
    errorMessage = firstError
    logger.error("Live concurrent transcription error: \(firstError, privacy: .public)")
}
```

- [ ] **Step 4: Build**

Run:

```bash
xcodebuild -project falsoai-lens.xcodeproj -scheme falsoai-lens -configuration Debug build
```

Expected: `BUILD SUCCEEDED`.

---

### Task 5: Manual Verification

**Files:**
- No code changes.

- [ ] **Step 1: Launch from Xcode**

Start the app from Xcode so the current signed entitlements are used.

- [ ] **Step 2: Verify microphone-only speech**

Scenario:
- Keep computer/system audio silent.
- Speak into the microphone for at least 6 seconds.

Expected:
- Logs show `Separated chunk emitted source=microphone`.
- Microphone lane receives text.
- Computer Audio lane remains empty unless system audio is actually playing the same speech.

- [ ] **Step 3: Verify computer-only audio**

Scenario:
- Play a video/audio source on the computer.
- Do not speak.

Expected:
- Logs show `Separated chunk emitted source=computer`.
- Computer Audio lane receives text.
- Microphone lane remains empty unless speakers bleed into the mic.

- [ ] **Step 4: Verify both sources simultaneously**

Scenario:
- Play computer audio.
- Speak into the microphone at the same time.

Expected:
- Logs show batches where both microphone and computer chunks are transcribed in the same processing cycle.
- Microphone speech appears in Microphone.
- Computer speech appears in Computer Audio.
- UI remains responsive.

---

## Self-Review

**Spec coverage:** The plan covers synchronized chunk emission, concurrent transcription, deterministic transcript commits, error visibility, and manual verification.

**Placeholder scan:** No placeholder task remains; every implementation step names exact files, code shape, and build command.

**Type consistency:** `SeparatedAudioChunkBatch`, `SourceTranscriptionOutput`, and changed return types are used consistently across tasks.

