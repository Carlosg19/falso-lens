# Source-Separated Transcript Document Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the live hearing pipeline's plain rolling transcript-only state with source-aware transcript chunks that are ready for future LLM analysis.

**Architecture:** Keep Whisper source-agnostic: it continues returning `TranscriptionResult`. The live transcription pipeline wraps each `TranscriptionResult` with capture-source metadata, live timeline timing, and segments converted to seconds since capture start. The UI can continue using `SourceTranscriptState.text`, while future export/LLM analysis can use `SourceSeparatedAudioTranscript.chunks`.

**Tech Stack:** Swift, SwiftUI, AVFoundation/AVAudioEngine, ScreenCaptureKit, Core Audio, local `whisper-cli`.

---

## File Structure

- Create `falsoai-lens/Pipelines/Hearing/Models/SourceSeparatedAudioTranscript.swift`
  - New Codable transcript document and chunk models.
  - Owns JSON-ready field names through `CodingKeys`.
- Modify `falsoai-lens/Pipelines/Hearing/Models/CapturedAudioPacket.swift`
  - Make `CapturedAudioSource` `Codable` so transcript chunks encode cleanly as `"computer"` / `"microphone"`.
- Modify `falsoai-lens/Pipelines/Hearing/Models/SourceTranscriptState.swift`
  - Add `chunks: [SourceTranscriptChunk]` while keeping `text` for existing UI panels.
- Modify `falsoai-lens/Pipelines/Hearing/Models/TranscriptionMode.swift`
  - Add a stable transcript/export value such as `"transcribe_original_language"`.
- Modify `falsoai-lens/Pipelines/Hearing/Services/AudioInputDeviceService.swift`
  - Add a helper to resolve a selected `AudioDeviceID` into the same display name used by the picker.
- Modify `falsoai-lens/Pipelines/Hearing/Services/LiveAudioCaptureProvider.swift`
  - Add `transcriptSource` metadata so each provider can identify its capture method.
- Modify `falsoai-lens/Pipelines/Hearing/Services/ComputerAudioCaptureService.swift`
  - Return source metadata for ScreenCaptureKit computer audio.
- Modify `falsoai-lens/Pipelines/Hearing/Services/MicrophoneAudioCaptureProvider.swift`
  - Return source metadata for AVAudioEngine microphone audio, including the selected input device name.
- Modify `falsoai-lens/Pipelines/Hearing/Services/LiveAudioTranscriptionPipeline.swift`
  - Convert `BufferedAudioChunk + TranscriptionResult` into `SourceTranscriptChunk`.
  - Append structured chunks and keep the existing deduplicated rolling `text`.

This plan intentionally does not add JSON export UI yet. It prepares the pipeline state so export or LLM analysis can be added cleanly afterward.

---

### Task 1: Add JSON-Ready Transcript Models

**Files:**
- Create: `falsoai-lens/Pipelines/Hearing/Models/SourceSeparatedAudioTranscript.swift`
- Modify: `falsoai-lens/Pipelines/Hearing/Models/CapturedAudioPacket.swift`
- Modify: `falsoai-lens/Pipelines/Hearing/Models/TranscriptionMode.swift`

- [ ] **Step 1: Make audio sources Codable**

Update `CapturedAudioSource` in `falsoai-lens/Pipelines/Hearing/Models/CapturedAudioPacket.swift`:

```swift
enum CapturedAudioSource: String, Sendable, Equatable, Codable {
    case computer
    case microphone
}
```

- [ ] **Step 2: Add transcript mode values**

Add this computed property to `TranscriptionMode` in `falsoai-lens/Pipelines/Hearing/Models/TranscriptionMode.swift`:

```swift
var transcriptValue: String {
    switch self {
    case .transcribeOriginalLanguage:
        return "transcribe_original_language"
    case .translateToEnglish:
        return "translate_to_english"
    }
}
```

- [ ] **Step 3: Create the transcript model file**

Create `falsoai-lens/Pipelines/Hearing/Models/SourceSeparatedAudioTranscript.swift`:

```swift
import Foundation

enum TranscriptCaptureMethod: String, Sendable, Equatable, Codable {
    case screenCaptureKit = "screen_capture_kit"
    case avAudioEngine = "av_audio_engine"
}

struct TranscriptSource: Sendable, Equatable, Codable {
    let source: CapturedAudioSource
    let captureMethod: TranscriptCaptureMethod
    let inputDevice: String?

    nonisolated init(
        source: CapturedAudioSource,
        captureMethod: TranscriptCaptureMethod,
        inputDevice: String? = nil
    ) {
        self.source = source
        self.captureMethod = captureMethod
        self.inputDevice = inputDevice
    }

    enum CodingKeys: String, CodingKey {
        case source
        case captureMethod = "capture_method"
        case inputDevice = "input_device"
    }
}

struct SourceTranscriptSegment: Sendable, Equatable, Codable {
    let startTime: TimeInterval
    let endTime: TimeInterval
    let text: String

    nonisolated init(
        startTime: TimeInterval,
        endTime: TimeInterval,
        text: String
    ) {
        self.startTime = startTime
        self.endTime = endTime
        self.text = text
    }

    enum CodingKeys: String, CodingKey {
        case startTime = "start_time"
        case endTime = "end_time"
        case text
    }
}

struct SourceTranscriptChunk: Sendable, Equatable, Identifiable, Codable {
    let chunkID: String
    let source: CapturedAudioSource
    let sequenceNumber: Int
    let startTime: TimeInterval
    let endTime: TimeInterval
    let duration: TimeInterval
    let language: String?
    let text: String
    let segments: [SourceTranscriptSegment]

    nonisolated var id: String { chunkID }

    nonisolated init(
        chunkID: String,
        source: CapturedAudioSource,
        sequenceNumber: Int,
        startTime: TimeInterval,
        endTime: TimeInterval,
        duration: TimeInterval,
        language: String?,
        text: String,
        segments: [SourceTranscriptSegment]
    ) {
        self.chunkID = chunkID
        self.source = source
        self.sequenceNumber = sequenceNumber
        self.startTime = startTime
        self.endTime = endTime
        self.duration = duration
        self.language = language
        self.text = text
        self.segments = segments
    }

    enum CodingKeys: String, CodingKey {
        case chunkID = "chunk_id"
        case source
        case sequenceNumber = "sequence_number"
        case startTime = "start_time"
        case endTime = "end_time"
        case duration
        case language
        case text
        case segments
    }
}

struct SourceSeparatedAudioTranscript: Sendable, Equatable, Codable {
    let schemaVersion: Int
    let language: String?
    let mode: String
    let timebase: String
    let sources: [TranscriptSource]
    let chunks: [SourceTranscriptChunk]

    nonisolated init(
        schemaVersion: Int = 1,
        language: String?,
        mode: TranscriptionMode,
        sources: [TranscriptSource],
        chunks: [SourceTranscriptChunk]
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
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case language
        case mode
        case timebase
        case sources
        case chunks
    }
}
```

- [ ] **Step 4: Build**

Run:

```bash
xcodebuild -project falsoai-lens.xcodeproj -scheme falsoai-lens -configuration Debug build
```

Expected: build succeeds.

---

### Task 2: Store Structured Chunks in Source Transcript State

**Files:**
- Modify: `falsoai-lens/Pipelines/Hearing/Models/SourceTranscriptState.swift`

- [ ] **Step 1: Add chunk storage without breaking existing UI**

Replace the current `SourceTranscriptState` with:

```swift
import Foundation

struct SourceTranscriptState: Sendable, Equatable {
    let source: CapturedAudioSource
    var text = ""
    var chunks: [SourceTranscriptChunk] = []
    var chunksTranscribed = 0
    var latestLanguage: String?
    var lastInferenceDurationSeconds: Double?

    var isEmpty: Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
```

`text` remains the deduplicated, display-friendly transcript used by `ContentView`. `chunks` becomes the structured data for future JSON export and LLM analysis.

- [ ] **Step 2: Build**

Run:

```bash
xcodebuild -project falsoai-lens.xcodeproj -scheme falsoai-lens -configuration Debug build
```

Expected: build succeeds.

---

### Task 3: Add Capture Source Metadata to Providers

**Files:**
- Modify: `falsoai-lens/Pipelines/Hearing/Services/AudioInputDeviceService.swift`
- Modify: `falsoai-lens/Pipelines/Hearing/Services/LiveAudioCaptureProvider.swift`
- Modify: `falsoai-lens/Pipelines/Hearing/Services/ComputerAudioCaptureService.swift`
- Modify: `falsoai-lens/Pipelines/Hearing/Services/MicrophoneAudioCaptureProvider.swift`

- [ ] **Step 1: Add a device display-name lookup helper**

Add this method to `AudioInputDeviceService` after `defaultInputDeviceID()`:

```swift
nonisolated static func displayName(for deviceID: AudioDeviceID) throws -> String {
    let name = try stringProperty(kAudioObjectPropertyName, for: deviceID) ?? "Input \(deviceID)"
    let manufacturer = try stringProperty(kAudioObjectPropertyManufacturer, for: deviceID)
    return AudioInputDevice(
        id: deviceID,
        name: name,
        manufacturer: manufacturer,
        isDefault: false
    ).displayName
}
```

- [ ] **Step 2: Extend the provider protocol**

Update `LiveAudioCaptureProvider`:

```swift
@MainActor
protocol LiveAudioCaptureProvider: AnyObject {
    var isRunning: Bool { get }
    var transcriptSource: TranscriptSource { get }

    func setInputDeviceID(_ deviceID: AudioDeviceID?)
    func startCapture() async throws -> AsyncStream<CapturedAudioBuffer>
    func stopCapture() async
}
```

- [ ] **Step 3: Add computer source metadata**

Add this computed property to `ComputerAudioCaptureService`:

```swift
var transcriptSource: TranscriptSource {
    TranscriptSource(
        source: .computer,
        captureMethod: .screenCaptureKit
    )
}
```

- [ ] **Step 4: Track microphone input device name**

Update `MicrophoneAudioCaptureProvider` to store the current input device display name:

```swift
@MainActor
final class MicrophoneAudioCaptureProvider: LiveAudioCaptureProvider {
    private let audioCaptureService: AudioCaptureService
    private var inputDeviceID: AudioDeviceID?
    private var inputDeviceName: String?

    var isRunning: Bool {
        audioCaptureService.isRunning
    }

    var transcriptSource: TranscriptSource {
        TranscriptSource(
            source: .microphone,
            captureMethod: .avAudioEngine,
            inputDevice: inputDeviceName ?? "System Default"
        )
    }

    init(audioCaptureService: AudioCaptureService? = nil) {
        self.audioCaptureService = audioCaptureService ?? AudioCaptureService()
    }

    func setInputDeviceID(_ deviceID: AudioDeviceID?) {
        guard !isRunning else { return }
        inputDeviceID = deviceID
        inputDeviceName = deviceID.flatMap { try? AudioInputDeviceService.displayName(for: $0) }
    }

    func startCapture() async throws -> AsyncStream<CapturedAudioBuffer> {
        var configuration = AudioCaptureConfiguration.default
        configuration.inputDeviceID = inputDeviceID
        return try audioCaptureService.startCapture(configuration: configuration)
    }

    func stopCapture() async {
        audioCaptureService.stopCapture()
    }
}
```

- [ ] **Step 5: Build**

Run:

```bash
xcodebuild -project falsoai-lens.xcodeproj -scheme falsoai-lens -configuration Debug build
```

Expected: build succeeds.

---

### Task 4: Convert Whisper Results Into Source Transcript Chunks

**Files:**
- Modify: `falsoai-lens/Pipelines/Hearing/Services/LiveAudioTranscriptionPipeline.swift`

- [ ] **Step 1: Expose provider source metadata from the pipeline**

Add this computed property near `hasTranscriptText`:

```swift
var transcriptSource: TranscriptSource {
    captureProvider.transcriptSource
}
```

- [ ] **Step 2: Pass the buffered chunk into append**

In `transcribe(chunk:normalizer:engine:mode:)`, replace:

```swift
append(result: output.result, elapsed: output.elapsed)
```

with:

```swift
append(result: output.result, chunk: chunk, elapsed: output.elapsed)
```

- [ ] **Step 3: Replace append with structured chunk construction**

Replace the current `append(result:elapsed:)` method with:

```swift
private func append(
    result: TranscriptionResult,
    chunk: BufferedAudioChunk,
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
}
```

- [ ] **Step 4: Add the chunk conversion helper**

Add this helper below `append(result:chunk:elapsed:)`:

```swift
private nonisolated static func makeTranscriptChunk(
    source: CapturedAudioSource,
    chunk: BufferedAudioChunk,
    result: TranscriptionResult,
    text: String
) -> SourceTranscriptChunk {
    let startTime = Double(chunk.startFrame) / chunk.sampleRate
    let duration = chunk.duration
    let endTime = startTime + duration
    let chunkID = "\(source.rawValue)_\(String(format: "%03d", chunk.sequenceNumber))"

    let segments = result.segments.compactMap { segment -> SourceTranscriptSegment? in
        let segmentText = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !segmentText.isEmpty else { return nil }

        let relativeStart = max(0, segment.startTime ?? 0)
        let relativeEnd = max(relativeStart, segment.endTime ?? relativeStart)

        return SourceTranscriptSegment(
            startTime: startTime + relativeStart,
            endTime: startTime + relativeEnd,
            text: segmentText
        )
    }

    return SourceTranscriptChunk(
        chunkID: chunkID,
        source: source,
        sequenceNumber: chunk.sequenceNumber,
        startTime: startTime,
        endTime: endTime,
        duration: duration,
        language: result.language,
        text: text,
        segments: segments
    )
}
```

- [ ] **Step 5: Build**

Run:

```bash
xcodebuild -project falsoai-lens.xcodeproj -scheme falsoai-lens -configuration Debug build
```

Expected: build succeeds.

---

### Task 5: Add a Combined Transcript Document Builder

**Files:**
- Modify: `falsoai-lens/ContentView.swift`

- [ ] **Step 1: Add a computed transcript document**

Add this computed property near the live audio helpers in `ContentView`:

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
            + microphoneHearing.transcript.chunks
    )
}
```

This does not display or export the document yet. It proves the pipeline can assemble the JSON-ready object from the two independent source pipelines.

- [ ] **Step 2: Add a debug-only assertion to keep the value used**

Inside `clearLiveAudioTranscripts()`, before clearing both transcript states, add:

```swift
#if DEBUG
_ = liveTranscriptDocument
#endif
```

This keeps the computed document compiled and type-checked without changing the UI.

- [ ] **Step 3: Build**

Run:

```bash
xcodebuild -project falsoai-lens.xcodeproj -scheme falsoai-lens -configuration Debug build
```

Expected: build succeeds.

---

### Task 6: Verify the Structured Transcript Pipeline

**Files:**
- Inspect only.

- [ ] **Step 1: Verify new transcript models exist**

Run:

```bash
rg -n "SourceSeparatedAudioTranscript|SourceTranscriptChunk|SourceTranscriptSegment|TranscriptSource" falsoai-lens/Pipelines/Hearing
```

Expected: matches in:

- `falsoai-lens/Pipelines/Hearing/Models/SourceSeparatedAudioTranscript.swift`
- `falsoai-lens/Pipelines/Hearing/Models/SourceTranscriptState.swift`
- `falsoai-lens/Pipelines/Hearing/Services/LiveAudioTranscriptionPipeline.swift`
- capture provider files

- [ ] **Step 2: Verify Whisper stays source-agnostic**

Run:

```bash
rg -n "CapturedAudioSource|TranscriptSource|SourceTranscriptChunk" falsoai-lens/Pipelines/Hearing/Inference falsoai-lens/Pipelines/Hearing/Services/WhisperCppEngine.swift falsoai-lens/Pipelines/Hearing/Models/TranscriptionResult.swift
```

Expected: no matches in `WhisperCppEngine.swift` or `TranscriptionResult.swift`. If there are matches, remove them and keep source handling in `LiveAudioTranscriptionPipeline`.

- [ ] **Step 3: Verify UI still displays source-specific text**

Run:

```bash
rg -n "computerHearing\\.transcript\\.text|microphoneHearing\\.transcript\\.text|liveTranscriptPanel" falsoai-lens/ContentView.swift
```

Expected: the computer panel still reads `computerHearing.transcript`, the microphone panel still reads `microphoneHearing.transcript`, and copy buttons still use each source's `transcript.text`.

- [ ] **Step 4: Final build**

Run:

```bash
xcodebuild -project falsoai-lens.xcodeproj -scheme falsoai-lens -configuration Debug build
```

Expected: `** BUILD SUCCEEDED **`. The existing warning about the `Re-sign bundled whisper-cli` run script may remain.

---

## Manual Verification

After implementation:

1. Launch the app from Xcode.
2. Select the virtual cable or microphone from `Microphone Input`.
3. Start live capture.
4. Speak into the selected microphone and play computer audio.
5. Confirm the UI still shows separate computer and microphone panels.
6. Confirm logs show source-specific chunk appends for `computer` and `microphone`.
7. Add temporary debug logging of `liveTranscriptDocument.chunks.count` only if needed, then remove it before finishing.

This plan prepares the transcript pipeline for future LLM analysis without adding persistence, export, cross-source dedupe, or speaker diarization.
