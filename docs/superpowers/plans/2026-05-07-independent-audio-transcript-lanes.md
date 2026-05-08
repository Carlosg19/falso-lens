# Independent Audio Transcript Lanes Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make microphone and computer transcripts fully independent so neither source suppresses, moves, promotes, deduplicates against, or otherwise rewrites the other source's transcript.

**Architecture:** Preserve source identity from capture through buffering, normalization, transcription, and UI publication. Keep concurrent batch transcription, but remove transcript-layer arbitration: each `SourceTranscriptionOutput` must append only to the `SourceTranscriptState` matching its original `BufferedAudioChunk.source`.

**Tech Stack:** Swift 5, SwiftUI, Swift concurrency, ScreenCaptureKit, AVAudioEngine, whisper.cpp CLI.

---

## Current Scan Summary

The codebase already has the right source boundaries in most places:

- `falsoai-lens/Pipelines/Hearing/Models/CapturedAudioPacket.swift` carries `source: CapturedAudioSource`.
- `falsoai-lens/Pipelines/Hearing/Models/BufferedAudioChunk.swift` carries `source: CapturedAudioSource`.
- `falsoai-lens/Pipelines/Hearing/Models/SeparatedAudioChunkBatch.swift` stores optional `microphone` and `computer` chunks separately.
- `falsoai-lens/Pipelines/Hearing/Services/MixedAudioBufferStore.swift` maintains `computerState` and `microphoneState` separately and emits chunks with the correct source.
- `falsoai-lens/ContentView.swift` already renders two separate lanes from `liveHearing.computerTranscript` and `liveHearing.microphoneTranscript`.

The architectural problem is concentrated in `falsoai-lens/Pipelines/Hearing/Services/LiveMixedAudioTranscriptionPipeline.swift`:

- `resolveSourceOwnership(...)` suppresses computer output when microphone output looks similar.
- `resolveSourceOwnership(...)` can reassign computer output to microphone with `assigningSource(.microphone)`.
- `append(result:source:elapsed:)` suppresses computer text if it resembles `microphoneTranscript.lastAcceptedText`.
- `append(result:source:elapsed:)` can remove text from the computer transcript when microphone text later appears.
- `SourceTranscriptState.lastAcceptedText` exists only to support cross-source arbitration.
- Helpers such as `isLikelySameUtterance`, `removingTrailingUtterance`, `sourceChunkLooksActive`, `sourceChunkLooksLeakedFromMicrophone`, `rmsDBFS`, `peakAmplitude`, `absoluteCorrelation`, and `normalizedWords` are now the wrong abstraction for transcript lanes.

## Files

- Modify: `falsoai-lens/Pipelines/Hearing/Services/LiveMixedAudioTranscriptionPipeline.swift`
- Verify only: `falsoai-lens/ContentView.swift`
- Verify only: `falsoai-lens/Pipelines/Hearing/Services/MixedAudioBufferStore.swift`
- Verify only: `falsoai-lens/Pipelines/Hearing/Models/SeparatedAudioChunkBatch.swift`

No UI layout change is expected. The UI already has independent panes; the service should simply stop rewriting source ownership before the panes receive state.

---

### Task 1: Confirm Forbidden Cross-Source Arbitration

**Files:**
- Inspect: `falsoai-lens/Pipelines/Hearing/Services/LiveMixedAudioTranscriptionPipeline.swift`

- [ ] **Step 1: Run a search for the current arbitration logic**

Run:

```bash
rg -n "resolveSourceOwnership|assigningSource|isLikelySameUtterance|removingTrailingUtterance|sourceChunkLooks|absoluteCorrelation|lastAcceptedText" falsoai-lens/Pipelines/Hearing/Services/LiveMixedAudioTranscriptionPipeline.swift
```

Expected before implementation: matches are present. These matches are the code paths that allow one source to affect the other.

- [ ] **Step 2: State the root cause before editing**

Record this in the implementation notes:

```text
Root cause: the pipeline treats microphone and computer transcription results as competing ownership candidates. The desired model is independent lanes, so source identity must never be reassigned or used to suppress another source.
```

---

### Task 2: Remove Source Reassignment From Transcription Output

**Files:**
- Modify: `falsoai-lens/Pipelines/Hearing/Services/LiveMixedAudioTranscriptionPipeline.swift`

- [ ] **Step 1: Simplify `SourceTranscriptState`**

Replace:

```swift
struct SourceTranscriptState: Sendable, Equatable {
    let source: CapturedAudioSource
    var text = ""
    var chunksTranscribed = 0
    var latestLanguage: String?
    var lastInferenceDurationSeconds: Double?
    var lastAcceptedText: String?

    var isEmpty: Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
```

With:

```swift
struct SourceTranscriptState: Sendable, Equatable {
    let source: CapturedAudioSource
    var text = ""
    var chunksTranscribed = 0
    var latestLanguage: String?
    var lastInferenceDurationSeconds: Double?

    var isEmpty: Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
```

- [ ] **Step 2: Simplify `SourceTranscriptionOutput`**

Replace:

```swift
private struct SourceTranscriptionOutput: Sendable {
    let source: CapturedAudioSource
    let result: TranscriptionResult
    let elapsed: Double
    let errorMessage: String?

    var trimmedText: String {
        result.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func assigningSource(_ source: CapturedAudioSource) -> SourceTranscriptionOutput {
        SourceTranscriptionOutput(
            source: source,
            result: result,
            elapsed: elapsed,
            errorMessage: errorMessage
        )
    }
}
```

With:

```swift
private struct SourceTranscriptionOutput: Sendable {
    let source: CapturedAudioSource
    let result: TranscriptionResult
    let elapsed: Double
    let errorMessage: String?
}
```

- [ ] **Step 3: Verify the reassignment helper is gone**

Run:

```bash
rg -n "assigningSource|trimmedText" falsoai-lens/Pipelines/Hearing/Services/LiveMixedAudioTranscriptionPipeline.swift
```

Expected after this task: no matches.

---

### Task 3: Append Concurrent Outputs Directly To Their Own Source

**Files:**
- Modify: `falsoai-lens/Pipelines/Hearing/Services/LiveMixedAudioTranscriptionPipeline.swift`

- [ ] **Step 1: Replace the resolved-output append block**

Replace:

```swift
let resolvedOutputs = Self.resolveSourceOwnership(
    outputs,
    microphoneChunk: batch.microphone,
    computerChunk: batch.computer
)

for source in [CapturedAudioSource.microphone, .computer] {
    for output in resolvedOutputs where output.source == source {
        append(
            result: output.result,
            source: output.source,
            elapsed: output.elapsed
        )
    }
}
```

With:

```swift
for source in [CapturedAudioSource.microphone, .computer] {
    for output in outputs where output.source == source {
        append(
            result: output.result,
            source: output.source,
            elapsed: output.elapsed
        )
    }
}
```

- [ ] **Step 2: Delete `resolveSourceOwnership(...)`**

Delete the entire method:

```swift
private nonisolated static func resolveSourceOwnership(
    _ outputs: [SourceTranscriptionOutput],
    microphoneChunk: BufferedAudioChunk?,
    computerChunk: BufferedAudioChunk?
) -> [SourceTranscriptionOutput] {
    ...
}
```

- [ ] **Step 3: Verify no batch-level ownership resolver remains**

Run:

```bash
rg -n "resolveSourceOwnership|microphoneChunk:|computerChunk:" falsoai-lens/Pipelines/Hearing/Services/LiveMixedAudioTranscriptionPipeline.swift
```

Expected after this task: no matches for `resolveSourceOwnership`; no `microphoneChunk:` or `computerChunk:` arguments in `LiveMixedAudioTranscriptionPipeline.swift`.

---

### Task 4: Remove Cross-Source Suppression From `append`

**Files:**
- Modify: `falsoai-lens/Pipelines/Hearing/Services/LiveMixedAudioTranscriptionPipeline.swift`

- [ ] **Step 1: Replace `append(result:source:elapsed:)`**

Replace the current method body with this source-local version:

```swift
private func append(result: TranscriptionResult, source: CapturedAudioSource, elapsed: Double) {
    var state = transcriptState(for: source)
    state.lastInferenceDurationSeconds = elapsed

    let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else {
        setTranscriptState(state)
        statusText = "No voice detected in the latest \(source.displayName.lowercased()) audio window."
        return
    }

    state.text = Self.appendDeduplicating(
        existing: state.text,
        addition: text
    )
    state.chunksTranscribed += 1
    state.latestLanguage = result.language ?? state.latestLanguage
    setTranscriptState(state)
    errorMessage = nil

    logger.info(
        "Live separated transcription appended source=\(source.rawValue, privacy: .public), characters=\(text.count, privacy: .public), chunks=\(state.chunksTranscribed, privacy: .public), elapsedSeconds=\(elapsed, privacy: .public), language=\(result.language ?? "nil", privacy: .public)"
    )
}
```

- [ ] **Step 2: Verify `append` has no cross-source reads**

Run:

```bash
rg -n "microphoneTranscript\\.lastAcceptedText|computerTranscript\\.lastAcceptedText|removingTrailingUtterance|isLikelySameUtterance" falsoai-lens/Pipelines/Hearing/Services/LiveMixedAudioTranscriptionPipeline.swift
```

Expected after this task: no matches.

---

### Task 5: Delete Dead Cross-Source Helper Functions

**Files:**
- Modify: `falsoai-lens/Pipelines/Hearing/Services/LiveMixedAudioTranscriptionPipeline.swift`

- [ ] **Step 1: Delete no-longer-used helper methods**

Delete these methods from `LiveMixedAudioTranscriptionPipeline`:

```swift
nonisolated static func isLikelySameUtterance(_ lhs: String, _ rhs: String?) -> Bool
nonisolated static func removingTrailingUtterance(_ utterance: String, from transcript: String) -> String
private nonisolated static func sourceChunkLooksActive(_ chunk: BufferedAudioChunk) -> Bool
private nonisolated static func sourceChunkLooksLeakedFromMicrophone(microphoneChunk: BufferedAudioChunk, computerChunk: BufferedAudioChunk?) -> Bool
private nonisolated static func rmsDBFS(for samples: [Float]) -> Double
private nonisolated static func peakAmplitude(for samples: [Float]) -> Float
private nonisolated static func absoluteCorrelation(_ lhs: [Float], _ rhs: [Float]) -> Double
private nonisolated static func normalizedWords(_ text: String) -> [String]
```

- [ ] **Step 2: Update the debug smoke check**

Replace the cross-source assertions in `runStateSmokeCheck()`:

```swift
assert(
    isLikelySameUtterance("hello from the microphone", "Hello, from the microphone."),
    "Expected transcript source comparison to ignore punctuation and case"
)
assert(
    removingTrailingUtterance("hello from the microphone", from: "hello from the microphone") == "",
    "Expected duplicate source text to be removable when microphone owns it"
)
```

With:

```swift
computer.text = appendDeduplicating(existing: computer.text, addition: "same phrase")
microphone.text = appendDeduplicating(existing: microphone.text, addition: "same phrase")
assert(
    computer.text.contains("same phrase") && microphone.text.contains("same phrase"),
    "Expected identical source text to remain independently visible in both transcript states"
)
```

- [ ] **Step 3: Verify no dead helper symbols remain**

Run:

```bash
rg -n "isLikelySameUtterance|removingTrailingUtterance|sourceChunkLooks|rmsDBFS|peakAmplitude|absoluteCorrelation|normalizedWords|lastAcceptedText" falsoai-lens/Pipelines/Hearing/Services/LiveMixedAudioTranscriptionPipeline.swift
```

Expected after this task: no matches.

---

### Task 6: Verify UI Still Reads Independent Published State

**Files:**
- Inspect only: `falsoai-lens/ContentView.swift`

- [ ] **Step 1: Confirm the computer lane still reads only computer state**

Run:

```bash
rg -n "Copy Computer|Computer Audio|liveHearing\\.computerTranscript" falsoai-lens/ContentView.swift
```

Expected: matches show `Copy Computer` uses `liveHearing.computerTranscript.text`, and the `Computer Audio` lane receives `state: liveHearing.computerTranscript`.

- [ ] **Step 2: Confirm the microphone lane still reads only microphone state**

Run:

```bash
rg -n "Copy Mic|Microphone|liveHearing\\.microphoneTranscript" falsoai-lens/ContentView.swift
```

Expected: matches show `Copy Mic` uses `liveHearing.microphoneTranscript.text`, and the `Microphone` lane receives `state: liveHearing.microphoneTranscript`.

- [ ] **Step 3: Do not change UI code unless this verification fails**

Expected: no UI edits are needed.

---

### Task 7: Verify Source Identity Is Still Preserved Below Transcript Layer

**Files:**
- Inspect only: `falsoai-lens/Pipelines/Hearing/Services/MixedAudioBufferStore.swift`
- Inspect only: `falsoai-lens/Pipelines/Hearing/Models/SeparatedAudioChunkBatch.swift`
- Inspect only: `falsoai-lens/Pipelines/Hearing/Models/BufferedAudioChunk.swift`
- Inspect only: `falsoai-lens/Pipelines/Hearing/Models/CapturedAudioPacket.swift`

- [ ] **Step 1: Confirm packet and chunk models still carry source**

Run:

```bash
rg -n "let source: CapturedAudioSource|case computer|case microphone" falsoai-lens/Pipelines/Hearing/Models
```

Expected: `CapturedAudioPacket` and `BufferedAudioChunk` both have `let source: CapturedAudioSource`; `CapturedAudioSource` has `computer` and `microphone`.

- [ ] **Step 2: Confirm buffer store still emits per-source chunks**

Run:

```bash
rg -n "computerState|microphoneState|nextChunk\\(for: \\.computer\\)|nextChunk\\(for: \\.microphone\\)|source: source" falsoai-lens/Pipelines/Hearing/Services/MixedAudioBufferStore.swift
```

Expected: matches show separate source states and `BufferedAudioChunk(source: source, ...)`.

- [ ] **Step 3: Confirm batch processing order does not rewrite source**

Run:

```bash
sed -n '1,80p' falsoai-lens/Pipelines/Hearing/Models/SeparatedAudioChunkBatch.swift
```

Expected:

```swift
var chunksInProcessingOrder: [BufferedAudioChunk] {
    [microphone, computer].compactMap { $0 }
}
```

This ordering is acceptable because it only controls commit order. It must not change `BufferedAudioChunk.source`.

---

### Task 8: Build Verification

**Files:**
- Build all Swift sources.

- [ ] **Step 1: Run the debug build**

Run:

```bash
xcodebuild -project falsoai-lens.xcodeproj -scheme falsoai-lens -configuration Debug build
```

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 2: Run the forbidden-symbol check again**

Run:

```bash
rg -n "resolveSourceOwnership|assigningSource|isLikelySameUtterance|removingTrailingUtterance|sourceChunkLooks|absoluteCorrelation|lastAcceptedText" falsoai-lens/Pipelines/Hearing/Services/LiveMixedAudioTranscriptionPipeline.swift
```

Expected: no matches.

---

### Task 9: Manual Runtime Verification

**Files:**
- Runtime verification in the app.

- [ ] **Step 1: Start separated capture**

Launch the app from Xcode, scroll to `Separated Live Audio`, and click `Start Separated Capture`.

Expected: status changes to `Listening to separated computer and microphone audio...`.

- [ ] **Step 2: Speak into the microphone while computer audio is silent**

Expected:

```text
Microphone pane: contains the spoken text if microphone transcription succeeds.
Computer Audio pane: remains empty unless the system audio capture really contains that microphone signal.
```

Important: the transcript layer must not move text from Computer Audio to Microphone. If microphone speech still appears in Computer Audio, that is evidence of capture leakage/routing, not transcript-layer arbitration.

- [ ] **Step 3: Play computer audio while staying silent**

Expected:

```text
Computer Audio pane: contains the played audio text.
Microphone pane: remains empty unless the physical microphone picks up speaker audio.
```

- [ ] **Step 4: Speak while computer audio is playing**

Expected:

```text
Computer Audio pane: shows only what the computer capture transcribed from its own source.
Microphone pane: shows only what the microphone capture transcribed from its own source.
Both panes may contain similar words if both capture paths truly heard similar audio.
Neither pane suppresses the other.
```

---

## Self-Review

Spec coverage:

- Independent microphone transcript: Task 3 and Task 4 append microphone output only to microphone state.
- Independent computer transcript: Task 3 and Task 4 append computer output only to computer state.
- No microphone suppression of computer audio: Task 3 deletes batch ownership resolution; Task 4 deletes source-local suppression based on microphone state.
- No computer-to-microphone promotion: Task 2 deletes `assigningSource`; Task 3 deletes `resolveSourceOwnership`.
- UI remains separate: Task 6 verifies existing `ContentView` bindings.
- Build verification: Task 8 runs the required Xcode build.
- Runtime verification: Task 9 validates the behavior the user cares about.

Placeholder scan:

- No `TBD`, `TODO`, `implement later`, or unspecified test steps remain.

Type consistency:

- `SourceTranscriptState` no longer exposes `lastAcceptedText`.
- `SourceTranscriptionOutput` no longer exposes `trimmedText` or `assigningSource`.
- Later tasks do not reference deleted helper methods except in forbidden-symbol checks.
