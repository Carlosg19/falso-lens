# Cross-Source Duplicate Annotations Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a non-mutating, cross-source duplicate-annotation layer that flags suspected duplicate transcript chunks between the computer and microphone live audio pipelines without modifying either source's `SourceTranscriptState`.

**Architecture:** Lift the proven similarity helpers (`isLikelySameUtterance`, `absoluteCorrelation`, `normalizedWords`, RMS gates) from the orphan `LiveMixedAudioTranscriptionPipeline` into a reusable static helper enum. Build a new `@MainActor` `TranscriptDuplicateAnalyzer` that observes both pipelines via a chunk-event hook, maintains a per-source sliding window of recent chunks (with normalized PCM samples), and emits a `DuplicateAnnotation` whenever a confidence-weighted score exceeds the threshold. Annotations live as an optional sibling field on `SourceSeparatedAudioTranscript`, preserving the existing "independent transcript lanes" invariant. After the lift, delete the orphan mixed-pipeline files.

**Tech Stack:** Swift 5, SwiftUI, Swift concurrency (`@MainActor`, `Task.detached`), Foundation, existing `LiveAudioTranscriptionPipeline` and `AudioNormalizer` infrastructure.

---

## File Structure

**Create:**

- `falsoai-lens/Pipelines/Hearing/Models/DuplicateAnnotation.swift`
  - Codable annotation struct.
- `falsoai-lens/Pipelines/Hearing/Models/LiveTranscriptChunkEvent.swift`
  - Sendable struct that carries a finalized `SourceTranscriptChunk` plus its 16 kHz mono PCM samples to the analyzer.
- `falsoai-lens/Pipelines/Hearing/Inference/TranscriptSimilarityHelpers.swift`
  - Static helpers lifted from `LiveMixedAudioTranscriptionPipeline.swift`: text normalization, Jaccard utterance match, PCM cross-correlation, RMS dBFS, peak amplitude.
- `falsoai-lens/Pipelines/Hearing/Services/TranscriptDuplicateAnalyzer.swift`
  - `@MainActor ObservableObject` that ingests `LiveTranscriptChunkEvent`s, runs scoring on a detached task, and publishes `annotations: [DuplicateAnnotation]`.

**Modify:**

- `falsoai-lens/Pipelines/Hearing/Models/SourceSeparatedAudioTranscript.swift`
  - Add optional `annotations: [DuplicateAnnotation]?` sibling field, `CodingKeys`, and update the initializer.
- `falsoai-lens/Pipelines/Hearing/Services/LiveAudioTranscriptionPipeline.swift`
  - Capture normalized samples from `AudioNormalizer.normalize(_:)` (the pipeline currently discards them via `normalizeToTemporaryWAV`).
  - Add a `chunkHook` callback, invoked after a successful `append(...)`, that emits `LiveTranscriptChunkEvent`.
- `falsoai-lens/ContentView.swift`
  - Add `@StateObject duplicateAnalyzer = TranscriptDuplicateAnalyzer()`.
  - Wire the chunk hook on both pipelines.
  - Include `duplicateAnalyzer.annotations` in `liveTranscriptDocument`.
  - Show a small annotation count next to the chunk counts in the live audio header for visibility.
- `falsoai-lens/Pipelines/Hearing/Services/HearingDemoPipeline.swift`
  - Replace `MixedAudioBufferStore.runSeparatedSourceSmokeCheck()` with `TranscriptDuplicateAnalyzer.runDuplicateSmokeCheck()` (the orphan store is being deleted in Task 8).

**Delete (Task 8):**

- `falsoai-lens/Pipelines/Hearing/Services/LiveMixedAudioTranscriptionPipeline.swift`
- `falsoai-lens/Pipelines/Hearing/Services/MixedAudioBufferStore.swift`
- `falsoai-lens/Pipelines/Hearing/Services/ComputerMicrophoneAudioCaptureService.swift`
- `falsoai-lens/Pipelines/Hearing/Models/SeparatedAudioChunkBatch.swift`

This plan does not add or change UI styling for flagged chunks. The annotations are surfaced as a count only; rendering them as fades, badges, or filters is intentionally out of scope.

---

### Task 1: Add the `DuplicateAnnotation` Model

**Files:**
- Create: `falsoai-lens/Pipelines/Hearing/Models/DuplicateAnnotation.swift`

- [ ] **Step 1: Create the annotation file**

```swift
import Foundation

struct DuplicateAnnotation: Sendable, Equatable, Identifiable, Codable {
    let chunkID: String
    let duplicateOfChunkID: String
    let confidence: Double
    let signals: [String]

    nonisolated var id: String { chunkID }

    nonisolated init(
        chunkID: String,
        duplicateOfChunkID: String,
        confidence: Double,
        signals: [String]
    ) {
        self.chunkID = chunkID
        self.duplicateOfChunkID = duplicateOfChunkID
        self.confidence = confidence
        self.signals = signals
    }

    enum CodingKeys: String, CodingKey {
        case chunkID = "chunk_id"
        case duplicateOfChunkID = "duplicate_of_chunk_id"
        case confidence
        case signals
    }
}
```

- [ ] **Step 2: Build**

Run:

```bash
xcodebuild -project falsoai-lens.xcodeproj -scheme falsoai-lens -configuration Debug build
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Commit**

```bash
git add falsoai-lens/Pipelines/Hearing/Models/DuplicateAnnotation.swift
git commit -m "feat(hearing): add DuplicateAnnotation model"
```

---

### Task 2: Lift Similarity Helpers Into a Reusable Enum

**Files:**
- Create: `falsoai-lens/Pipelines/Hearing/Inference/TranscriptSimilarityHelpers.swift`

The current `LiveMixedAudioTranscriptionPipeline` owns the proven helpers but is orphan code. Move the math (no behavior changes) into a freestanding enum so the new analyzer can use it without depending on the legacy pipeline. The legacy file is deleted in Task 8.

- [ ] **Step 1: Create the helpers file**

```swift
import Foundation

enum TranscriptSimilarityHelpers {
    nonisolated static func normalizedWords(_ text: String) -> [String] {
        let foldedText = text.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: .current
        )
        let allowedCharacters = CharacterSet.alphanumerics.union(.whitespacesAndNewlines)
        let cleanedScalars = foldedText.unicodeScalars.map { scalar in
            allowedCharacters.contains(scalar) ? Character(scalar) : " "
        }

        return String(cleanedScalars)
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
    }

    nonisolated static func isLikelySameUtterance(_ lhs: String, _ rhs: String?) -> Bool {
        guard let rhs else { return false }

        let lhsWords = normalizedWords(lhs)
        let rhsWords = normalizedWords(rhs)
        guard !lhsWords.isEmpty, !rhsWords.isEmpty else { return false }

        let lhsJoined = lhsWords.joined(separator: " ")
        let rhsJoined = rhsWords.joined(separator: " ")
        if lhsJoined == rhsJoined {
            return true
        }

        let shorter = lhsJoined.count <= rhsJoined.count ? lhsJoined : rhsJoined
        let longer = lhsJoined.count > rhsJoined.count ? lhsJoined : rhsJoined
        if shorter.count >= 24, longer.contains(shorter) {
            return true
        }

        let lhsSet = Set(lhsWords)
        let rhsSet = Set(rhsWords)
        let overlapCount = lhsSet.intersection(rhsSet).count
        let smallerCount = min(lhsSet.count, rhsSet.count)
        guard smallerCount >= 4 else { return false }

        return Double(overlapCount) / Double(smallerCount) >= 0.82
    }

    nonisolated static func absoluteCorrelation(_ lhs: [Float], _ rhs: [Float]) -> Double {
        let count = min(lhs.count, rhs.count)
        guard count > 0 else { return 0 }

        var dotProduct = 0.0
        var lhsEnergy = 0.0
        var rhsEnergy = 0.0

        for index in 0..<count {
            let lhsSample = Double(lhs[index])
            let rhsSample = Double(rhs[index])
            dotProduct += lhsSample * rhsSample
            lhsEnergy += lhsSample * lhsSample
            rhsEnergy += rhsSample * rhsSample
        }

        guard lhsEnergy > 0, rhsEnergy > 0 else { return 0 }
        return abs(dotProduct / sqrt(lhsEnergy * rhsEnergy))
    }

    nonisolated static func rmsDBFS(for samples: [Float]) -> Double {
        guard !samples.isEmpty else { return -.infinity }
        let squareSum = samples.reduce(Double.zero) { partialResult, sample in
            partialResult + Double(sample * sample)
        }
        let rms = sqrt(squareSum / Double(samples.count))
        guard rms > 0 else { return -.infinity }
        return 20 * log10(rms)
    }

    nonisolated static func peakAmplitude(for samples: [Float]) -> Float {
        samples.reduce(Float.zero) { partialResult, sample in
            max(partialResult, abs(sample))
        }
    }
}
```

- [ ] **Step 2: Build**

Run:

```bash
xcodebuild -project falsoai-lens.xcodeproj -scheme falsoai-lens -configuration Debug build
```

Expected: `** BUILD SUCCEEDED **`. The orphan `LiveMixedAudioTranscriptionPipeline.swift` still defines its own copies; that is fine — it is deleted in Task 8.

- [ ] **Step 3: Commit**

```bash
git add falsoai-lens/Pipelines/Hearing/Inference/TranscriptSimilarityHelpers.swift
git commit -m "feat(hearing): lift transcript similarity helpers into reusable enum"
```

---

### Task 3: Add the Chunk-Event Model

**Files:**
- Create: `falsoai-lens/Pipelines/Hearing/Models/LiveTranscriptChunkEvent.swift`

The analyzer needs both the finalized `SourceTranscriptChunk` (text + timing) and the 16 kHz mono normalized PCM samples for cross-correlation. This is the wire format between the pipeline and the analyzer.

- [ ] **Step 1: Create the event file**

```swift
import Foundation

struct LiveTranscriptChunkEvent: Sendable {
    let chunk: SourceTranscriptChunk
    let normalizedSamples: [Float]
    let normalizedSampleRate: Double

    nonisolated init(
        chunk: SourceTranscriptChunk,
        normalizedSamples: [Float],
        normalizedSampleRate: Double
    ) {
        self.chunk = chunk
        self.normalizedSamples = normalizedSamples
        self.normalizedSampleRate = normalizedSampleRate
    }
}
```

- [ ] **Step 2: Build**

Run:

```bash
xcodebuild -project falsoai-lens.xcodeproj -scheme falsoai-lens -configuration Debug build
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Commit**

```bash
git add falsoai-lens/Pipelines/Hearing/Models/LiveTranscriptChunkEvent.swift
git commit -m "feat(hearing): add LiveTranscriptChunkEvent for cross-pipeline duplicate analysis"
```

---

### Task 4: Emit Chunk Events From `LiveAudioTranscriptionPipeline`

**Files:**
- Modify: `falsoai-lens/Pipelines/Hearing/Services/LiveAudioTranscriptionPipeline.swift`

Today, `transcribeOutput(...)` calls `normalizer.normalizeToTemporaryWAV(...)` and discards the returned `NormalizedAudioChunk` after Whisper reads the WAV file. We need to keep the `samples` from that `NormalizedAudioChunk` so they can flow to the analyzer. `NormalizedAudioChunk` already carries `.samples` (verified in `falsoai-lens/Pipelines/Hearing/Models/NormalizedAudioChunk.swift`), so no normalizer change is required.

- [ ] **Step 1: Extend the internal output struct to carry normalized samples**

Replace the existing `SourceTranscriptionOutput` struct at the bottom of `LiveAudioTranscriptionPipeline.swift`:

```swift
private struct SourceTranscriptionOutput: Sendable {
    let result: TranscriptionResult
    let normalizedSamples: [Float]
    let normalizedSampleRate: Double
    let elapsed: Double
    let errorMessage: String?
}
```

- [ ] **Step 2: Capture normalized samples in `transcribeOutput`**

Replace `transcribeOutput(chunk:normalizer:engine:mode:)` with this version. The structure is the same; the only change is keeping the `normalizedChunk` samples around in both branches:

```swift
private nonisolated static func transcribeOutput(
    chunk: BufferedAudioChunk,
    normalizer: AudioNormalizer,
    engine: TranscriptionEngine,
    mode: TranscriptionMode
) async -> SourceTranscriptionOutput {
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
            result: result,
            normalizedSamples: normalizedChunk.samples,
            normalizedSampleRate: normalizedChunk.sampleRate,
            elapsed: Date().timeIntervalSince(started),
            errorMessage: nil
        )
    } catch {
        return SourceTranscriptionOutput(
            result: TranscriptionResult(text: "", segments: [], language: nil, duration: 0),
            normalizedSamples: [],
            normalizedSampleRate: 0,
            elapsed: Date().timeIntervalSince(started),
            errorMessage: Self.userFacingMessage(for: error)
        )
    }
}
```

- [ ] **Step 3: Add the chunk-hook storage and setter**

Add a stored property and setter to `LiveAudioTranscriptionPipeline`. Place the property near the other private state (after `private var captureTask: Task<Void, Never>?`):

```swift
private var chunkHook: (@Sendable (LiveTranscriptChunkEvent) -> Void)?
```

Add this method just below `setInputDeviceID(_:)`:

```swift
func setChunkHook(_ hook: (@Sendable (LiveTranscriptChunkEvent) -> Void)?) {
    self.chunkHook = hook
}
```

- [ ] **Step 4: Pass normalized samples through `transcribe(...)` to `append(...)`**

Update the call inside `transcribe(chunk:normalizer:engine:mode:)`. Replace:

```swift
} else {
    append(result: output.result, chunk: chunk, elapsed: output.elapsed)
}
```

with:

```swift
} else {
    append(
        result: output.result,
        chunk: chunk,
        normalizedSamples: output.normalizedSamples,
        normalizedSampleRate: output.normalizedSampleRate,
        elapsed: output.elapsed
    )
}
```

- [ ] **Step 5: Update `append(...)` to accept normalized samples and fire the hook**

Replace the current `append(result:chunk:elapsed:)` with:

```swift
private func append(
    result: TranscriptionResult,
    chunk: BufferedAudioChunk,
    normalizedSamples: [Float],
    normalizedSampleRate: Double,
    elapsed: Double
) {
    transcript.lastInferenceDurationSeconds = elapsed

    let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else {
        statusText = "No voice detected in the latest \(source.displayName.lowercased()) audio window."
        return
    }

    let transcriptChunk = Self.makeTranscriptChunk(
        source: source,
        chunk: chunk,
        result: result,
        text: text
    )

    transcript.chunks.append(transcriptChunk)
    transcript.text = Self.appendDeduplicating(
        existing: transcript.text,
        addition: text
    )
    transcript.chunksTranscribed += 1
    transcript.latestLanguage = result.language ?? transcript.latestLanguage
    errorMessage = nil

    logger.info(
        "\(self.source.rawValue, privacy: .public) transcription appended characters=\(text.count, privacy: .public), chunks=\(self.transcript.chunksTranscribed, privacy: .public), elapsedSeconds=\(elapsed, privacy: .public), language=\(result.language ?? "nil", privacy: .public)"
    )

    if let chunkHook, !normalizedSamples.isEmpty, normalizedSampleRate > 0 {
        let event = LiveTranscriptChunkEvent(
            chunk: transcriptChunk,
            normalizedSamples: normalizedSamples,
            normalizedSampleRate: normalizedSampleRate
        )
        chunkHook(event)
    }
}
```

- [ ] **Step 6: Build**

Run:

```bash
xcodebuild -project falsoai-lens.xcodeproj -scheme falsoai-lens -configuration Debug build
```

Expected: `** BUILD SUCCEEDED **`. No analyzer is wired yet — the hook is `nil` for now, so behavior is unchanged.

- [ ] **Step 7: Commit**

```bash
git add falsoai-lens/Pipelines/Hearing/Services/LiveAudioTranscriptionPipeline.swift
git commit -m "feat(hearing): emit chunk events with normalized PCM from live pipeline"
```

---

### Task 5: Build the `TranscriptDuplicateAnalyzer`

**Files:**
- Create: `falsoai-lens/Pipelines/Hearing/Services/TranscriptDuplicateAnalyzer.swift`

The analyzer keeps a per-source sliding window (last 20 chunks or 30 seconds, whichever is smaller). When a chunk arrives, it compares only against the *other* source's window. Scoring runs on a detached task to keep the main actor responsive. Pairs are tracked by an unordered key so the same pair is never annotated twice.

- [ ] **Step 1: Create the analyzer file**

```swift
import Combine
import Foundation
import OSLog

@MainActor
final class TranscriptDuplicateAnalyzer: ObservableObject {
    @Published private(set) var annotations: [DuplicateAnnotation] = []

    private struct WindowEntry {
        let chunk: SourceTranscriptChunk
        let samples: [Float]
        let sampleRate: Double
    }

    private struct DuplicateScore: Sendable {
        let confidence: Double
        let signals: [String]
    }

    private static let confidenceThreshold = 0.50
    private static let timeGateSeconds = 0.5
    private static let maxWindowEntries = 20
    private static let maxWindowSeconds: TimeInterval = 30

    private var windows: [CapturedAudioSource: [WindowEntry]] = [
        .computer: [],
        .microphone: []
    ]
    private var seenPairs: Set<String> = []
    private let logger: Logger

    init(
        logger: Logger = Logger(
            subsystem: Bundle.main.bundleIdentifier ?? "com.falsoai.FalsoaiLens",
            category: "TranscriptDuplicateAnalyzer"
        )
    ) {
        self.logger = logger
    }

    func ingest(_ event: LiveTranscriptChunkEvent) {
        let entry = WindowEntry(
            chunk: event.chunk,
            samples: event.normalizedSamples,
            sampleRate: event.normalizedSampleRate
        )

        var sourceWindow = windows[event.chunk.source] ?? []
        sourceWindow.append(entry)
        sourceWindow = Self.trimWindow(sourceWindow, referenceTime: event.chunk.endTime)
        windows[event.chunk.source] = sourceWindow

        let otherSource: CapturedAudioSource = event.chunk.source == .computer ? .microphone : .computer
        let candidates = windows[otherSource] ?? []

        guard !candidates.isEmpty else { return }

        Task.detached(priority: .utility) { [weak self, entry, candidates] in
            let scoredPairs = Self.scoreCandidates(new: entry, candidates: candidates)

            await MainActor.run {
                self?.applyScoredPairs(newEntry: entry, scoredPairs: scoredPairs)
            }
        }
    }

    func reset() {
        windows = [.computer: [], .microphone: []]
        seenPairs.removeAll()
        annotations.removeAll()
    }

    private func applyScoredPairs(
        newEntry: WindowEntry,
        scoredPairs: [(SourceTranscriptChunk, DuplicateScore)]
    ) {
        for (candidateChunk, score) in scoredPairs {
            let pairKey = Self.pairKey(newEntry.chunk.chunkID, candidateChunk.chunkID)
            guard !seenPairs.contains(pairKey) else { continue }
            guard score.confidence >= Self.confidenceThreshold else { continue }

            let (primary, duplicate) = Self.orderPair(newEntry.chunk, candidateChunk)
            let annotation = DuplicateAnnotation(
                chunkID: duplicate.chunkID,
                duplicateOfChunkID: primary.chunkID,
                confidence: score.confidence,
                signals: score.signals
            )
            annotations.append(annotation)
            seenPairs.insert(pairKey)

            logger.info(
                "Duplicate annotated chunkID=\(annotation.chunkID, privacy: .public) duplicateOf=\(annotation.duplicateOfChunkID, privacy: .public) confidence=\(annotation.confidence, privacy: .public) signals=\(annotation.signals.joined(separator: ","), privacy: .public)"
            )
        }
    }

    private nonisolated static func trimWindow(
        _ window: [WindowEntry],
        referenceTime: TimeInterval
    ) -> [WindowEntry] {
        let cutoff = referenceTime - maxWindowSeconds
        var trimmed = window.filter { $0.chunk.endTime >= cutoff }
        if trimmed.count > maxWindowEntries {
            trimmed.removeFirst(trimmed.count - maxWindowEntries)
        }
        return trimmed
    }

    private nonisolated static func scoreCandidates(
        new: WindowEntry,
        candidates: [WindowEntry]
    ) -> [(SourceTranscriptChunk, DuplicateScore)] {
        candidates.compactMap { candidate in
            guard timeWindowOverlap(new.chunk, candidate.chunk) else { return nil }
            let score = scoreDuplicate(new: new, candidate: candidate)
            return (candidate.chunk, score)
        }
    }

    private nonisolated static func timeWindowOverlap(
        _ a: SourceTranscriptChunk,
        _ b: SourceTranscriptChunk
    ) -> Bool {
        let earliest = min(a.startTime, b.startTime)
        let latest = max(a.endTime, b.endTime)
        let unionDuration = latest - earliest
        let summedDuration = a.duration + b.duration
        if summedDuration > unionDuration { return true }
        return abs(a.startTime - b.startTime) < timeGateSeconds
    }

    private nonisolated static func scoreDuplicate(
        new: WindowEntry,
        candidate: WindowEntry
    ) -> DuplicateScore {
        var confidence = 0.0
        var signals: [String] = []

        let timeDelta = abs(new.chunk.startTime - candidate.chunk.startTime)
        if timeDelta < 0.300 {
            confidence += 0.10
            signals.append("time_overlap")
        }

        if candidate.chunk.duration > 0 {
            let durationRatio = new.chunk.duration / candidate.chunk.duration
            if durationRatio > 0.85, durationRatio < 1.15 {
                confidence += 0.05
                signals.append("duration_match")
            }
        }

        if let lhsLanguage = new.chunk.language,
           let rhsLanguage = candidate.chunk.language,
           lhsLanguage == rhsLanguage {
            confidence += 0.05
            signals.append("language_match")
        }

        if TranscriptSimilarityHelpers.isLikelySameUtterance(new.chunk.text, candidate.chunk.text) {
            confidence += 0.45
            signals.append("text_jaccard")
        }

        if !new.samples.isEmpty,
           !candidate.samples.isEmpty,
           new.sampleRate == candidate.sampleRate {
            let pcmCorr = TranscriptSimilarityHelpers.absoluteCorrelation(
                new.samples,
                candidate.samples
            )
            if pcmCorr >= 0.50 {
                confidence += 0.35
                signals.append("pcm_correlation")
            }
        }

        let newWordCount = TranscriptSimilarityHelpers.normalizedWords(new.chunk.text).count
        let candidateWordCount = TranscriptSimilarityHelpers.normalizedWords(candidate.chunk.text).count
        if newWordCount < 3 || candidateWordCount < 3 {
            confidence *= 0.3
            signals.append("filler_penalty")
        }

        return DuplicateScore(
            confidence: min(1.0, confidence),
            signals: signals
        )
    }

    private nonisolated static func orderPair(
        _ a: SourceTranscriptChunk,
        _ b: SourceTranscriptChunk
    ) -> (primary: SourceTranscriptChunk, duplicate: SourceTranscriptChunk) {
        if a.startTime != b.startTime {
            return a.startTime < b.startTime ? (a, b) : (b, a)
        }
        if a.source == .computer, b.source != .computer {
            return (a, b)
        }
        if b.source == .computer, a.source != .computer {
            return (b, a)
        }
        return a.chunkID <= b.chunkID ? (a, b) : (b, a)
    }

    private nonisolated static func pairKey(_ lhs: String, _ rhs: String) -> String {
        lhs <= rhs ? "\(lhs)|\(rhs)" : "\(rhs)|\(lhs)"
    }

    #if DEBUG
    nonisolated static func runDuplicateSmokeCheck() {
        let computerChunk = SourceTranscriptChunk(
            chunkID: "computer_001",
            source: .computer,
            sequenceNumber: 1,
            startTime: 5.0,
            endTime: 10.0,
            duration: 5.0,
            language: "en",
            text: "The deadline is tomorrow morning.",
            segments: []
        )
        let microphoneChunk = SourceTranscriptChunk(
            chunkID: "microphone_001",
            source: .microphone,
            sequenceNumber: 1,
            startTime: 5.05,
            endTime: 10.05,
            duration: 5.0,
            language: "en",
            text: "the deadline is tomorrow morning",
            segments: []
        )
        let computerEntry = WindowEntry(
            chunk: computerChunk,
            samples: [],
            sampleRate: 16_000
        )
        let microphoneEntry = WindowEntry(
            chunk: microphoneChunk,
            samples: [],
            sampleRate: 16_000
        )

        let pairs = scoreCandidates(new: microphoneEntry, candidates: [computerEntry])
        assert(pairs.count == 1, "Expected one scored pair for near-identical text")
        let (matchedChunk, score) = pairs[0]
        assert(matchedChunk.chunkID == "computer_001", "Expected match to be the computer chunk")
        assert(score.confidence >= confidenceThreshold, "Expected confidence above threshold for near-identical utterance")
        assert(score.signals.contains("text_jaccard"), "Expected text_jaccard signal to fire")

        let unrelatedChunk = SourceTranscriptChunk(
            chunkID: "computer_002",
            source: .computer,
            sequenceNumber: 2,
            startTime: 60.0,
            endTime: 65.0,
            duration: 5.0,
            language: "en",
            text: "Completely different topic about lunch.",
            segments: []
        )
        let unrelatedEntry = WindowEntry(
            chunk: unrelatedChunk,
            samples: [],
            sampleRate: 16_000
        )
        let unrelatedPairs = scoreCandidates(new: microphoneEntry, candidates: [unrelatedEntry])
        assert(unrelatedPairs.isEmpty, "Expected unrelated chunks outside the time gate to be filtered")

        let fillerChunkA = SourceTranscriptChunk(
            chunkID: "computer_003",
            source: .computer,
            sequenceNumber: 3,
            startTime: 5.0,
            endTime: 10.0,
            duration: 5.0,
            language: "en",
            text: "Thanks.",
            segments: []
        )
        let fillerChunkB = SourceTranscriptChunk(
            chunkID: "microphone_003",
            source: .microphone,
            sequenceNumber: 3,
            startTime: 5.05,
            endTime: 10.05,
            duration: 5.0,
            language: "en",
            text: "Thanks.",
            segments: []
        )
        let fillerA = WindowEntry(chunk: fillerChunkA, samples: [], sampleRate: 16_000)
        let fillerB = WindowEntry(chunk: fillerChunkB, samples: [], sampleRate: 16_000)
        let fillerPairs = scoreCandidates(new: fillerB, candidates: [fillerA])
        assert(fillerPairs.count == 1, "Expected filler pair to still produce a score entry")
        assert(fillerPairs[0].1.confidence < confidenceThreshold, "Expected filler-word penalty to drop confidence below threshold")
        assert(fillerPairs[0].1.signals.contains("filler_penalty"), "Expected filler_penalty signal to fire")

        let (primary, duplicate) = orderPair(microphoneChunk, computerChunk)
        assert(primary.chunkID == "computer_001", "Expected earlier-start computer chunk to be primary")
        assert(duplicate.chunkID == "microphone_001", "Expected later mic chunk to be the duplicate")
    }
    #endif
}
```

- [ ] **Step 2: Build**

Run:

```bash
xcodebuild -project falsoai-lens.xcodeproj -scheme falsoai-lens -configuration Debug build
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Commit**

```bash
git add falsoai-lens/Pipelines/Hearing/Services/TranscriptDuplicateAnalyzer.swift
git commit -m "feat(hearing): add TranscriptDuplicateAnalyzer with sliding window and confidence scoring"
```

---

### Task 6: Add Annotations to the Transcript Document

**Files:**
- Modify: `falsoai-lens/Pipelines/Hearing/Models/SourceSeparatedAudioTranscript.swift`

- [ ] **Step 1: Replace the `SourceSeparatedAudioTranscript` struct**

Replace the existing `SourceSeparatedAudioTranscript` definition (currently lines 100–139 in `falsoai-lens/Pipelines/Hearing/Models/SourceSeparatedAudioTranscript.swift`) with:

```swift
struct SourceSeparatedAudioTranscript: Sendable, Equatable, Codable {
    let schemaVersion: Int
    let language: String?
    let mode: String
    let timebase: String
    let sources: [TranscriptSource]
    let chunks: [SourceTranscriptChunk]
    let annotations: [DuplicateAnnotation]?

    nonisolated init(
        schemaVersion: Int = 1,
        language: String?,
        mode: TranscriptionMode,
        sources: [TranscriptSource],
        chunks: [SourceTranscriptChunk],
        annotations: [DuplicateAnnotation]? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.language = language
        self.mode = mode.transcriptValue
        self.timebase = "seconds_since_capture_start"
        self.sources = sources
        self.chunks = chunks.sorted { lhs, rhs in
            if lhs.startTime != rhs.startTime {
                return lhs.startTime < rhs.startTime
            }
            if lhs.source.rawValue != rhs.source.rawValue {
                return lhs.source.rawValue < rhs.source.rawValue
            }
            return lhs.sequenceNumber < rhs.sequenceNumber
        }
        self.annotations = annotations?.isEmpty == true ? nil : annotations
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case language
        case mode
        case timebase
        case sources
        case chunks
        case annotations
    }
}
```

- [ ] **Step 2: Build**

Run:

```bash
xcodebuild -project falsoai-lens.xcodeproj -scheme falsoai-lens -configuration Debug build
```

Expected: `** BUILD SUCCEEDED **`. `ContentView`'s existing `SourceSeparatedAudioTranscript(...)` call still compiles because the new `annotations` parameter has a default value.

- [ ] **Step 3: Commit**

```bash
git add falsoai-lens/Pipelines/Hearing/Models/SourceSeparatedAudioTranscript.swift
git commit -m "feat(hearing): add optional annotations field to source-separated transcript"
```

---

### Task 7: Wire the Analyzer Into `ContentView`

**Files:**
- Modify: `falsoai-lens/ContentView.swift`

- [ ] **Step 1: Add the analyzer state object**

Insert this line in `ContentView`'s state declarations, immediately after the `microphoneHearing` `@StateObject` (currently line 18):

```swift
@StateObject private var duplicateAnalyzer = TranscriptDuplicateAnalyzer()
```

- [ ] **Step 2: Wire the chunk hook on both pipelines**

Replace the existing `.task` block (currently around line 215):

```swift
.task {
    await refreshPermissions()
    audioInputDevices.refresh()
    microphoneHearing.setInputDeviceID(audioInputDevices.selectedDeviceID)
}
```

with:

```swift
.task {
    await refreshPermissions()
    audioInputDevices.refresh()
    microphoneHearing.setInputDeviceID(audioInputDevices.selectedDeviceID)

    let analyzer = duplicateAnalyzer
    computerHearing.setChunkHook { [weak analyzer] event in
        Task { @MainActor in
            analyzer?.ingest(event)
        }
    }
    microphoneHearing.setChunkHook { [weak analyzer] event in
        Task { @MainActor in
            analyzer?.ingest(event)
        }
    }
}
```

- [ ] **Step 3: Include annotations in the live transcript document**

Replace the `liveTranscriptDocument` computed property:

```swift
private var liveTranscriptDocument: SourceSeparatedAudioTranscript {
    SourceSeparatedAudioTranscript(
        language: microphoneHearing.transcript.latestLanguage
            ?? computerHearing.transcript.latestLanguage,
        mode: hearingMode,
        sources: [
            computerHearing.transcriptSource,
            microphoneHearing.transcriptSource
        ],
        chunks: computerHearing.transcript.chunks
            + microphoneHearing.transcript.chunks,
        annotations: duplicateAnalyzer.annotations
    )
}
```

- [ ] **Step 4: Reset analyzer state when clearing transcripts**

Update `clearLiveAudioTranscripts()`:

```swift
private func clearLiveAudioTranscripts() {
    #if DEBUG
    _ = liveTranscriptDocument
    #endif

    computerHearing.clearTranscript()
    microphoneHearing.clearTranscript()
    duplicateAnalyzer.reset()
}
```

- [ ] **Step 5: Show the annotation count in the live audio header**

Replace the existing chunk-count `Text` (currently around line 429):

```swift
Text("Computer \(computerHearing.transcript.chunksTranscribed) | Mic \(microphoneHearing.transcript.chunksTranscribed)")
    .font(.caption)
    .foregroundStyle(.secondary)
```

with:

```swift
Text("Computer \(computerHearing.transcript.chunksTranscribed) | Mic \(microphoneHearing.transcript.chunksTranscribed) | Dups \(duplicateAnalyzer.annotations.count)")
    .font(.caption)
    .foregroundStyle(.secondary)
```

- [ ] **Step 6: Build**

Run:

```bash
xcodebuild -project falsoai-lens.xcodeproj -scheme falsoai-lens -configuration Debug build
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 7: Commit**

```bash
git add falsoai-lens/ContentView.swift
git commit -m "feat(hearing): wire TranscriptDuplicateAnalyzer into live audio UI"
```

---

### Task 8: Delete the Orphan Mixed-Pipeline Files

**Files:**
- Delete: `falsoai-lens/Pipelines/Hearing/Services/LiveMixedAudioTranscriptionPipeline.swift`
- Delete: `falsoai-lens/Pipelines/Hearing/Services/MixedAudioBufferStore.swift`
- Delete: `falsoai-lens/Pipelines/Hearing/Services/ComputerMicrophoneAudioCaptureService.swift`
- Delete: `falsoai-lens/Pipelines/Hearing/Models/SeparatedAudioChunkBatch.swift`
- Modify: `falsoai-lens/Pipelines/Hearing/Services/HearingDemoPipeline.swift`

These four files have been orphaned since `ContentView` switched to two independent `LiveAudioTranscriptionPipeline` instances. The only remaining reference is `MixedAudioBufferStore.runSeparatedSourceSmokeCheck()` inside `HearingDemoPipeline.init`. Replace that smoke check with the new analyzer's smoke check, then delete all four files.

- [ ] **Step 1: Confirm there are no other references**

Run:

```bash
grep -rn "LiveMixedAudioTranscriptionPipeline\|MixedAudioBufferStore\|ComputerMicrophoneAudioCaptureService\|SeparatedAudioChunkBatch" falsoai-lens/ docs/ scripts/ BundledResources/
```

Expected: matches only inside the four files themselves and in `falsoai-lens/Pipelines/Hearing/Services/HearingDemoPipeline.swift`. If any other file references them, stop and surface the additional references — do not silently delete.

- [ ] **Step 2: Replace the smoke check in `HearingDemoPipeline.swift`**

Inside `HearingDemoPipeline.swift`, in the `#if DEBUG` block (currently around line 39–44), replace:

```swift
#if DEBUG
WhisperCppEngine.runParserSmokeCheck()
RMSVoiceActivityDetector.runVADSmokeCheck()
MixedAudioBufferStore.runSeparatedSourceSmokeCheck()
LiveAudioTranscriptionPipeline.runStateSmokeCheck()
#endif
```

with:

```swift
#if DEBUG
WhisperCppEngine.runParserSmokeCheck()
RMSVoiceActivityDetector.runVADSmokeCheck()
TranscriptDuplicateAnalyzer.runDuplicateSmokeCheck()
LiveAudioTranscriptionPipeline.runStateSmokeCheck()
#endif
```

- [ ] **Step 3: Delete the four orphan files**

Run:

```bash
git rm falsoai-lens/Pipelines/Hearing/Services/LiveMixedAudioTranscriptionPipeline.swift falsoai-lens/Pipelines/Hearing/Services/MixedAudioBufferStore.swift falsoai-lens/Pipelines/Hearing/Services/ComputerMicrophoneAudioCaptureService.swift falsoai-lens/Pipelines/Hearing/Models/SeparatedAudioChunkBatch.swift
```

If `git rm` reports that some of these files are untracked (they currently appear under `??` in `git status`), use `rm` for those instead and `git rm` for the tracked ones. Combined safe form:

```bash
rm -f falsoai-lens/Pipelines/Hearing/Services/LiveMixedAudioTranscriptionPipeline.swift falsoai-lens/Pipelines/Hearing/Services/MixedAudioBufferStore.swift falsoai-lens/Pipelines/Hearing/Services/ComputerMicrophoneAudioCaptureService.swift falsoai-lens/Pipelines/Hearing/Models/SeparatedAudioChunkBatch.swift
```

- [ ] **Step 4: Build**

Run:

```bash
xcodebuild -project falsoai-lens.xcodeproj -scheme falsoai-lens -configuration Debug build
```

Expected: `** BUILD SUCCEEDED **`. If the build fails citing missing types from the deleted files, search for the symbol and remove the stray reference — do not restore the deleted files.

- [ ] **Step 5: Commit**

```bash
git add falsoai-lens/Pipelines/Hearing/Services/HearingDemoPipeline.swift
git add -u
git commit -m "chore(hearing): delete orphan mixed-pipeline files superseded by independent pipelines"
```

---

### Task 9: Verify the Annotation Pipeline End-to-End

**Files:**
- Inspect only.

- [ ] **Step 1: Confirm the new files exist and the helpers are reused**

Run:

```bash
rg -n "TranscriptDuplicateAnalyzer|TranscriptSimilarityHelpers|DuplicateAnnotation|LiveTranscriptChunkEvent" falsoai-lens/
```

Expected: matches in
- `falsoai-lens/Pipelines/Hearing/Models/DuplicateAnnotation.swift`
- `falsoai-lens/Pipelines/Hearing/Models/LiveTranscriptChunkEvent.swift`
- `falsoai-lens/Pipelines/Hearing/Models/SourceSeparatedAudioTranscript.swift`
- `falsoai-lens/Pipelines/Hearing/Inference/TranscriptSimilarityHelpers.swift`
- `falsoai-lens/Pipelines/Hearing/Services/TranscriptDuplicateAnalyzer.swift`
- `falsoai-lens/Pipelines/Hearing/Services/LiveAudioTranscriptionPipeline.swift`
- `falsoai-lens/Pipelines/Hearing/Services/HearingDemoPipeline.swift`
- `falsoai-lens/ContentView.swift`

- [ ] **Step 2: Confirm no transcript-state mutation across sources**

Run:

```bash
rg -n "computerHearing.transcript.text\s*=|microphoneHearing.transcript.text\s*=" falsoai-lens/
```

Expected: no matches. The analyzer must not assign to either `transcript.text`. The "independent transcript lanes" invariant must hold.

- [ ] **Step 3: Confirm the legacy mixed pipeline is gone**

Run:

```bash
rg -n "LiveMixedAudioTranscriptionPipeline|MixedAudioBufferStore|ComputerMicrophoneAudioCaptureService|SeparatedAudioChunkBatch" falsoai-lens/
```

Expected: no matches.

- [ ] **Step 4: Final build**

Run:

```bash
xcodebuild -project falsoai-lens.xcodeproj -scheme falsoai-lens -configuration Debug build
```

Expected: `** BUILD SUCCEEDED **`. The DEBUG smoke check `TranscriptDuplicateAnalyzer.runDuplicateSmokeCheck()` is invoked from `HearingDemoPipeline.init` so any logic regression in the scoring helpers will trip an `assert` at app launch in Debug builds.

---

## Manual Verification

After the build succeeds:

1. Launch the app from Xcode (Debug).
2. Grant Screen Recording, Microphone, and Notifications permissions if not already granted.
3. Select a virtual cable (e.g., BlackHole 2ch) as the Microphone Input. The duplicate scenario this plan targets requires the same source audio to reach both pipelines.
4. Press **Start Capture**.
5. Play 10–20 seconds of speech through an app whose audio routes through the virtual cable (e.g., a YouTube video while a Multi-Output Device sends to both speakers and BlackHole).
6. Observe the live audio header. It should read something like:
   `Computer N | Mic M | Dups K` with `K > 0` once the analyzer has scored at least one cross-source pair above threshold.
7. Stop capture, press **Clear Both**, and confirm the `Dups` counter resets to `0`.
8. Open Console.app and filter on `subsystem:com.falsoai.FalsoaiLens category:TranscriptDuplicateAnalyzer`. Confirm log lines of the form `Duplicate annotated chunkID=... duplicateOf=... confidence=... signals=...`.
9. Switch the Microphone Input back to your built-in mic, restart capture, and speak only into the mic while playing unrelated computer audio. Confirm the `Dups` counter stays at `0` (or near 0 — Whisper occasionally hallucinates filler that the filler penalty should suppress).

This plan intentionally does not implement: UI styling for flagged chunks (fade/badge/hide), JSON export of `liveTranscriptDocument`, virtual-cable detection at the picker level, or document-mode (text-only) duplicate analysis. Each of those is a separate plan once this annotation layer ships.
