# Audio Buffer Layer Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the Hearing pipeline's Audio Buffer Layer: an actor-backed rolling in-memory sample store that accepts `CapturedAudioBuffer` values, reports available audio duration, extracts raw fixed-duration sample windows, preserves overlap, and clears itself when recording stops.

**Architecture:** Add a focused buffer actor under `falsoai-lens/Pipelines/Hearing`. The capture layer already emits copied, Sendable sample buffers; this layer stores those samples in one format, protects mutable state with actor isolation, and exposes raw sample chunks for the later Chunking/Normalization layers. Do not implement WAV writing, resampling, mono conversion, Whisper execution, transcript assembly, or SwiftUI controls in this plan.

**Tech Stack:** Swift, Foundation, Swift actors, Sendable value types, existing `CapturedAudioBuffer`.

---

## Assumptions

- The current doc source of truth is `docs/Live Audio Transcriber Architecture.md`, especially section `4.2 Audio Buffer Layer`.
- `AudioCaptureService` already emits `AsyncStream<CapturedAudioBuffer>`.
- `CapturedAudioBuffer.samples` are interleaved by frame: frame 0 channel 0, frame 0 channel 1, frame 1 channel 0, etc.
- This layer should keep the input sample rate/channel count unchanged. Audio normalization to 16 kHz mono belongs to a later layer.
- There is no test target yet, so verification is build-based until a test target or manual UI smoke hook exists.

## File Structure

- Create `falsoai-lens/Pipelines/Hearing/Models/BufferedAudioChunk.swift`
  - Defines the raw sample chunk returned by the buffer actor.
  - Carries sequence number, start frame, sample rate, channel count, frame count, and sample data.
- Create `falsoai-lens/Pipelines/Hearing/Services/AudioBufferStore.swift`
  - Actor that owns the rolling sample array.
  - Appends `CapturedAudioBuffer` values.
  - Rejects incompatible sample rate/channel count changes.
  - Reports available frame count and duration.
  - Extracts a fixed-duration raw chunk and retains overlap.
  - Clears all state when recording stops.
- Modify `docs/Live Audio Transcriber Architecture.md`
  - Add an implementation boundary note under `4.2 Audio Buffer Layer`.

No Xcode project file edits are needed because `falsoai-lens/` is a file-system synchronized group.

---

### Task 1: Add Raw Buffered Chunk Model

**Files:**
- Create: `falsoai-lens/Pipelines/Hearing/Models/BufferedAudioChunk.swift`

- [x] **Step 1: Create the buffered chunk model**

Create `falsoai-lens/Pipelines/Hearing/Models/BufferedAudioChunk.swift`:

```swift
import Foundation

struct BufferedAudioChunk: Sendable, Equatable {
    let sequenceNumber: Int
    let startFrame: Int64
    let samples: [Float]
    let sampleRate: Double
    let channelCount: Int
    let frameCount: Int

    var duration: TimeInterval {
        guard sampleRate > 0 else { return 0 }
        return Double(frameCount) / sampleRate
    }
}
```

- [x] **Step 2: Build-check the model**

Run:

```bash
xcodebuild -project falsoai-lens.xcodeproj -scheme falsoai-lens -configuration Debug build
```

Expected: build succeeds.

---

### Task 2: Add Audio Buffer Store Actor

**Files:**
- Create: `falsoai-lens/Pipelines/Hearing/Services/AudioBufferStore.swift`

- [x] **Step 1: Create the actor file**

Create `falsoai-lens/Pipelines/Hearing/Services/AudioBufferStore.swift`:

```swift
import Foundation

enum AudioBufferStoreError: LocalizedError, Equatable {
    case invalidSampleLayout(expectedSamples: Int, actualSamples: Int)
    case incompatibleFormat(
        expectedSampleRate: Double,
        actualSampleRate: Double,
        expectedChannelCount: Int,
        actualChannelCount: Int
    )
    case invalidExtractionRequest(duration: TimeInterval, overlap: TimeInterval)

    var errorDescription: String? {
        switch self {
        case let .invalidSampleLayout(expectedSamples, actualSamples):
            return "Captured audio buffer sample layout is invalid. Expected \(expectedSamples) samples, got \(actualSamples)."
        case let .incompatibleFormat(expectedSampleRate, actualSampleRate, expectedChannelCount, actualChannelCount):
            return "Captured audio format changed from \(expectedSampleRate) Hz / \(expectedChannelCount) channels to \(actualSampleRate) Hz / \(actualChannelCount) channels."
        case let .invalidExtractionRequest(duration, overlap):
            return "Audio chunk extraction request is invalid. Duration \(duration)s must be greater than overlap \(overlap)s."
        }
    }
}

actor AudioBufferStore {
    private var samples: [Float] = []
    private var sampleRate: Double?
    private var channelCount: Int?
    private var absoluteStartFrame: Int64 = 0
    private var nextChunkSequenceNumber = 0

    var availableFrameCount: Int {
        guard let channelCount, channelCount > 0 else { return 0 }
        return samples.count / channelCount
    }

    var availableDuration: TimeInterval {
        guard let sampleRate, sampleRate > 0 else { return 0 }
        return Double(availableFrameCount) / sampleRate
    }

    func append(_ buffer: CapturedAudioBuffer) throws {
        guard buffer.frameCount > 0 else { return }
        guard buffer.channelCount > 0 else {
            throw AudioBufferStoreError.invalidSampleLayout(
                expectedSamples: 0,
                actualSamples: buffer.samples.count
            )
        }

        let expectedSamples = buffer.frameCount * buffer.channelCount
        guard buffer.samples.count == expectedSamples else {
            throw AudioBufferStoreError.invalidSampleLayout(
                expectedSamples: expectedSamples,
                actualSamples: buffer.samples.count
            )
        }

        try validateFormat(sampleRate: buffer.sampleRate, channelCount: buffer.channelCount)
        samples.append(contentsOf: buffer.samples)
    }

    func extractChunk(
        duration: TimeInterval,
        retainingOverlap overlap: TimeInterval
    ) throws -> BufferedAudioChunk? {
        guard duration > 0, overlap >= 0, overlap < duration else {
            throw AudioBufferStoreError.invalidExtractionRequest(
                duration: duration,
                overlap: overlap
            )
        }

        guard let sampleRate, let channelCount, channelCount > 0 else {
            return nil
        }

        let chunkFrameCount = max(1, Int((duration * sampleRate).rounded(.toNearestOrAwayFromZero)))
        let overlapFrameCount = Int((overlap * sampleRate).rounded(.toNearestOrAwayFromZero))
        guard overlapFrameCount < chunkFrameCount else {
            throw AudioBufferStoreError.invalidExtractionRequest(
                duration: duration,
                overlap: overlap
            )
        }

        guard availableFrameCount >= chunkFrameCount else {
            return nil
        }

        let chunkSampleCount = chunkFrameCount * channelCount
        let chunkSamples = Array(samples.prefix(chunkSampleCount))
        let chunk = BufferedAudioChunk(
            sequenceNumber: nextChunkSequenceNumber,
            startFrame: absoluteStartFrame,
            samples: chunkSamples,
            sampleRate: sampleRate,
            channelCount: channelCount,
            frameCount: chunkFrameCount
        )

        let framesToRemove = chunkFrameCount - overlapFrameCount
        let samplesToRemove = framesToRemove * channelCount
        samples.removeFirst(samplesToRemove)
        absoluteStartFrame += Int64(framesToRemove)
        nextChunkSequenceNumber += 1

        return chunk
    }

    func clear() {
        samples.removeAll(keepingCapacity: false)
        sampleRate = nil
        channelCount = nil
        absoluteStartFrame = 0
        nextChunkSequenceNumber = 0
    }

    private func validateFormat(sampleRate newSampleRate: Double, channelCount newChannelCount: Int) throws {
        guard let existingSampleRate = sampleRate, let existingChannelCount = channelCount else {
            sampleRate = newSampleRate
            channelCount = newChannelCount
            return
        }

        guard existingSampleRate == newSampleRate, existingChannelCount == newChannelCount else {
            throw AudioBufferStoreError.incompatibleFormat(
                expectedSampleRate: existingSampleRate,
                actualSampleRate: newSampleRate,
                expectedChannelCount: existingChannelCount,
                actualChannelCount: newChannelCount
            )
        }
    }
}
```

- [x] **Step 2: Build-check the actor**

Run:

```bash
xcodebuild -project falsoai-lens.xcodeproj -scheme falsoai-lens -configuration Debug build
```

Expected: build succeeds.

---

### Task 3: Add Buffer Layer Boundary To Architecture Doc

**Files:**
- Modify: `docs/Live Audio Transcriber Architecture.md`

- [x] **Step 1: Add an implementation note under `4.2 Audio Buffer Layer`**

Add this note after the numbered design notes in section `4.2 Audio Buffer Layer`:

```markdown
### Implementation Boundary

The app implementation keeps this layer focused on in-memory sample storage. It accepts copied `CapturedAudioBuffer` values, validates that the input format stays stable, tracks available duration, extracts raw sample windows when enough audio is available, retains overlap samples for the next extraction, and clears itself when recording stops. It does not resample, convert to mono, write WAV files, invoke Whisper, deduplicate transcript text, or update SwiftUI directly.
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
git diff --check -- falsoai-lens/Pipelines/Hearing 'docs/Live Audio Transcriber Architecture.md' docs/superpowers/plans/2026-05-06-audio-buffer-layer.md
```

Expected: no output and exit code 0.

- [x] **Step 2: Build the app**

Run:

```bash
xcodebuild -project falsoai-lens.xcodeproj -scheme falsoai-lens -configuration Debug build
```

Expected: build succeeds.

- [x] **Step 3: Confirm scope stayed within Audio Buffer Layer**

Run:

```bash
git status --short
```

Expected new or modified files for this layer:

```text
docs/Live Audio Transcriber Architecture.md
docs/superpowers/plans/2026-05-06-audio-buffer-layer.md
falsoai-lens/Pipelines/Hearing/Models/BufferedAudioChunk.swift
falsoai-lens/Pipelines/Hearing/Services/AudioBufferStore.swift
```

Existing unrelated workspace changes may also appear. Do not revert them. If UI, WAV writing, Whisper, or transcript files appear because of this task, stop and remove those changes from this layer.

---

## Notes For Execution

- This plan intentionally does not wire `AudioCaptureService` to `AudioBufferStore` in `ContentView`.
- The next layer can decide when to call `extractChunk(duration:retainingOverlap:)` with the MVP values from the architecture doc: 5 seconds and 1 second overlap.
- If `removeFirst(_:)` becomes a performance issue later, replace the backing array with a ring buffer. For the MVP, the array implementation is simpler and easier to verify.
