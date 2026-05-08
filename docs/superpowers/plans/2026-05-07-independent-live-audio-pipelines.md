# Independent Live Audio Pipelines Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the mixed live hearing path with two independent `LiveAudioTranscriptionPipeline` instances: one for computer audio and one for microphone audio.

**Architecture:** Use a reusable single-source `LiveAudioTranscriptionPipeline` that owns exactly one capture provider, one `AudioChunker`, one `AudioNormalizer`, one Whisper engine, and one `SourceTranscriptState`. Instantiate it twice in `ContentView`: a computer pipeline backed by ScreenCaptureKit system audio and a microphone pipeline backed by AVAudioEngine microphone input. Do not route either source through `ComputerMicrophoneAudioCaptureService`, `MixedAudioBufferStore`, `SeparatedAudioChunkBatch`, or any cross-source transcript ownership logic.

**Tech Stack:** Swift 5, SwiftUI, Swift concurrency, ScreenCaptureKit, AVAudioEngine, whisper.cpp CLI.

---

## Current Scan Summary

The current implementation still has a mixed path:

- `ComputerMicrophoneAudioCaptureService` starts ScreenCaptureKit computer audio and `AudioCaptureService` microphone audio together, then yields both as `CapturedAudioPacket`.
- `MixedAudioBufferStore` receives both sources and emits `SeparatedAudioChunkBatch`.
- `LiveMixedAudioTranscriptionPipeline` transcribes both sources in one object and still contains cross-source ownership logic (`resolveSourceOwnership`, `isLikelySameUtterance`, duplicate suppression, and moving text between states).
- `ContentView` owns a single `@StateObject private var liveHearing = LiveMixedAudioTranscriptionPipeline()`.

The desired design is not “mixed stream with source tags.” It is two independent pipelines:

```text
ComputerAudioCaptureService
  -> LiveAudioTranscriptionPipeline(source: .computer)
  -> computerTranscript panel

MicrophoneAudioCaptureProvider(AudioCaptureService)
  -> LiveAudioTranscriptionPipeline(source: .microphone)
  -> microphoneTranscript panel
```

Each pipeline runs independently. The two pipelines may run at the same time, but neither reads, suppresses, moves, deduplicates against, or reassigns text from the other.

## File Structure

Create:

- `falsoai-lens/Pipelines/Hearing/Models/SourceTranscriptState.swift`
  - Shared transcript state model used by each single-source pipeline and the UI.
- `falsoai-lens/Pipelines/Hearing/Services/LiveAudioCaptureProvider.swift`
  - Common single-source capture protocol.
- `falsoai-lens/Pipelines/Hearing/Services/MicrophoneAudioCaptureProvider.swift`
  - Adapter around existing `AudioCaptureService`.
- `falsoai-lens/Pipelines/Hearing/Services/ScreenCaptureAudioBufferReader.swift`
  - Shared ScreenCaptureKit sample-buffer-to-`CapturedAudioBuffer` converter.
- `falsoai-lens/Pipelines/Hearing/Services/ComputerAudioCaptureService.swift`
  - ScreenCaptureKit computer-audio-only capture provider.
- `falsoai-lens/Pipelines/Hearing/Services/LiveAudioTranscriptionPipeline.swift`
  - Single-source transcription pipeline.

Modify:

- `falsoai-lens/Pipelines/Hearing/Services/AudioBufferStore.swift`
  - Make chunk source configurable instead of hardcoded to `.microphone`.
- `falsoai-lens/Pipelines/Hearing/Services/AudioChunker.swift`
  - Pass the source into `AudioBufferStore`.
- `falsoai-lens/Pipelines/Hearing/Services/LiveMixedAudioTranscriptionPipeline.swift`
  - Remove the embedded `SourceTranscriptState` after moving it to the model file.
- `falsoai-lens/ContentView.swift`
  - Replace the single mixed `liveHearing` object with `computerHearing` and `microphoneHearing`.

Do not modify entitlements for this plan.

---

### Task 1: Confirm Mixed Path References Before Editing

**Files:**
- Inspect: `falsoai-lens/ContentView.swift`
- Inspect: `falsoai-lens/Pipelines/Hearing/Services/LiveMixedAudioTranscriptionPipeline.swift`
- Inspect: `falsoai-lens/Pipelines/Hearing/Services/MixedAudioBufferStore.swift`
- Inspect: `falsoai-lens/Pipelines/Hearing/Services/ComputerMicrophoneAudioCaptureService.swift`

- [ ] **Step 1: Search current mixed references**

Run:

```bash
rg -n "LiveMixedAudioTranscriptionPipeline|ComputerMicrophoneAudioCaptureService|MixedAudioBufferStore|SeparatedAudioChunkBatch|resolveSourceOwnership|lastAcceptedText" falsoai-lens
```

Expected before implementation: matches in `ContentView.swift`, `LiveMixedAudioTranscriptionPipeline.swift`, `MixedAudioBufferStore.swift`, and `ComputerMicrophoneAudioCaptureService.swift`.

- [ ] **Step 2: Record the root cause**

Implementation note:

```text
Root cause: the app still models computer and microphone live transcription as one mixed pipeline. Source tags are not enough because one object still owns both streams and can compare, delay, suppress, or rewrite one source based on the other.
```

---

### Task 2: Move `SourceTranscriptState` Into Models

**Files:**
- Create: `falsoai-lens/Pipelines/Hearing/Models/SourceTranscriptState.swift`
- Modify: `falsoai-lens/Pipelines/Hearing/Services/LiveMixedAudioTranscriptionPipeline.swift`

- [ ] **Step 1: Create the shared model**

Create `falsoai-lens/Pipelines/Hearing/Models/SourceTranscriptState.swift`:

```swift
import Foundation

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

- [ ] **Step 2: Remove the old embedded struct**

Delete this struct from the top of `falsoai-lens/Pipelines/Hearing/Services/LiveMixedAudioTranscriptionPipeline.swift`:

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

- [ ] **Step 3: Remove now-invalid `lastAcceptedText` writes in the mixed pipeline**

This mixed pipeline is being retired from UI, but it must still compile while the file exists. In `LiveMixedAudioTranscriptionPipeline.swift`, remove the lines that read or write `lastAcceptedText`:

```swift
if source == .computer, Self.isLikelySameUtterance(text, microphoneTranscript.lastAcceptedText) {
    ...
}

if source == .microphone, Self.isLikelySameUtterance(text, computerTranscript.lastAcceptedText) {
    ...
    computerState.lastAcceptedText = nil
    ...
}

state.lastAcceptedText = text
```

Replace the body of `append(result:source:elapsed:)` with a source-local version so the retired file compiles:

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

- [ ] **Step 4: Verify the model moved cleanly**

Run:

```bash
rg -n "struct SourceTranscriptState|lastAcceptedText" falsoai-lens/Pipelines/Hearing
```

Expected after this task:

```text
falsoai-lens/Pipelines/Hearing/Models/SourceTranscriptState.swift:3:struct SourceTranscriptState...
```

No `lastAcceptedText` matches.

---

### Task 3: Make `AudioBufferStore` Single-Source Configurable

**Files:**
- Modify: `falsoai-lens/Pipelines/Hearing/Services/AudioBufferStore.swift`
- Modify: `falsoai-lens/Pipelines/Hearing/Services/AudioChunker.swift`

- [ ] **Step 1: Add a source property to `AudioBufferStore`**

At the top of `AudioBufferStore`, add a source property and initializer:

```swift
actor AudioBufferStore {
    private let source: CapturedAudioSource
    private var samples: [Float] = []
    private var sampleRate: Double?
    private var channelCount: Int?
    private var absoluteStartFrame: Int64 = 0
    private var nextChunkSequenceNumber = 0

    init(source: CapturedAudioSource = .microphone) {
        self.source = source
    }
```

- [ ] **Step 2: Use the configured source when creating chunks**

In `extractChunk(duration:retainingOverlap:)`, replace:

```swift
let chunk = BufferedAudioChunk(
    source: .microphone,
```

With:

```swift
let chunk = BufferedAudioChunk(
    source: source,
```

- [ ] **Step 3: Add a source initializer to `AudioChunker`**

Replace the current `AudioChunker` initializer with:

```swift
init(
    source: CapturedAudioSource = .microphone,
    bufferStore: AudioBufferStore? = nil,
    configuration: AudioChunkingConfiguration = .mvp
) throws {
    try configuration.validate()
    self.bufferStore = bufferStore ?? AudioBufferStore(source: source)
    self.configuration = configuration
}
```

Keep the existing stored properties:

```swift
private let bufferStore: AudioBufferStore
private let configuration: AudioChunkingConfiguration
```

- [ ] **Step 4: Verify source is no longer hardcoded**

Run:

```bash
rg -n "source: \\.microphone" falsoai-lens/Pipelines/Hearing/Services/AudioBufferStore.swift falsoai-lens/Pipelines/Hearing/Services/AudioChunker.swift
```

Expected after this task: no matches in either file.

---

### Task 4: Add Single-Source Capture Provider Protocols

**Files:**
- Create: `falsoai-lens/Pipelines/Hearing/Services/LiveAudioCaptureProvider.swift`
- Create: `falsoai-lens/Pipelines/Hearing/Services/MicrophoneAudioCaptureProvider.swift`

- [ ] **Step 1: Create the provider protocol**

Create `falsoai-lens/Pipelines/Hearing/Services/LiveAudioCaptureProvider.swift`:

```swift
import Foundation

@MainActor
protocol LiveAudioCaptureProvider: AnyObject {
    var isRunning: Bool { get }

    func startCapture() async throws -> AsyncStream<CapturedAudioBuffer>
    func stopCapture() async
}
```

- [ ] **Step 2: Create the microphone adapter**

Create `falsoai-lens/Pipelines/Hearing/Services/MicrophoneAudioCaptureProvider.swift`:

```swift
import Foundation

@MainActor
final class MicrophoneAudioCaptureProvider: LiveAudioCaptureProvider {
    private let audioCaptureService: AudioCaptureService

    var isRunning: Bool {
        audioCaptureService.isRunning
    }

    init(audioCaptureService: AudioCaptureService = AudioCaptureService()) {
        self.audioCaptureService = audioCaptureService
    }

    func startCapture() async throws -> AsyncStream<CapturedAudioBuffer> {
        try audioCaptureService.startCapture()
    }

    func stopCapture() async {
        audioCaptureService.stopCapture()
    }
}
```

- [ ] **Step 3: Verify the protocol exists**

Run:

```bash
rg -n "protocol LiveAudioCaptureProvider|final class MicrophoneAudioCaptureProvider" falsoai-lens/Pipelines/Hearing/Services
```

Expected: both declarations are found.

---

### Task 5: Add Computer-Only ScreenCaptureKit Audio Capture

**Files:**
- Create: `falsoai-lens/Pipelines/Hearing/Services/ScreenCaptureAudioBufferReader.swift`
- Create: `falsoai-lens/Pipelines/Hearing/Services/ComputerAudioCaptureService.swift`

- [ ] **Step 1: Create a reusable sample-buffer reader**

Create `falsoai-lens/Pipelines/Hearing/Services/ScreenCaptureAudioBufferReader.swift` by moving the following helper methods from `ComputerMicrophoneAudioStreamOutput` into a `nonisolated enum`:

```swift
import CoreAudio
import CoreMedia
import Foundation

enum ScreenCaptureAudioBufferReader {
    static func capturedAudioBuffer(from sampleBuffer: CMSampleBuffer) throws -> CapturedAudioBuffer {
        // Move the existing implementation from ComputerMicrophoneAudioStreamOutput.capturedAudioBuffer(from:).
    }

    private static func maximumBufferCount(forAudioBufferListByteCount byteCount: Int) -> Int {
        // Move the existing implementation unchanged.
    }

    private static func copySamples(
        from audioBufferList: UnsafeMutableAudioBufferListPointer,
        streamDescription: AudioStreamBasicDescription,
        frameCount: Int,
        channelCount: Int
    ) throws -> [Float] {
        // Move the existing implementation unchanged.
    }

    private static func decodeSample(
        data: UnsafeMutableRawPointer,
        byteOffset: Int,
        streamDescription: AudioStreamBasicDescription
    ) -> Float {
        // Move the existing implementation unchanged.
    }
}
```

When moving the code, change thrown errors from `ComputerMicrophoneAudioCaptureError` to the new `ComputerAudioCaptureError` created in the next step.

- [ ] **Step 2: Create the computer capture service**

Create `falsoai-lens/Pipelines/Hearing/Services/ComputerAudioCaptureService.swift`:

```swift
import CoreGraphics
import CoreMedia
import Foundation
import OSLog
import ScreenCaptureKit

enum ComputerAudioCaptureError: LocalizedError {
    case alreadyRunning
    case screenRecordingPermissionDenied
    case noDisplayAvailable
    case unsupportedAudioFormat(formatID: AudioFormatID)
    case sampleBufferUnavailable(OSStatus)

    var errorDescription: String? {
        switch self {
        case .alreadyRunning:
            return "Computer audio capture is already running."
        case .screenRecordingPermissionDenied:
            return "Screen Recording permission is required before computer audio can be captured."
        case .noDisplayAvailable:
            return "No display was available for computer audio capture."
        case let .unsupportedAudioFormat(formatID):
            return "ScreenCaptureKit returned an unsupported audio format ID \(formatID)."
        case let .sampleBufferUnavailable(status):
            return "Could not read computer audio samples from ScreenCaptureKit. Core Media status \(status)."
        }
    }

    var recoverySuggestion: String? {
        switch self {
        case .alreadyRunning:
            return "Stop the current computer audio capture before starting another one."
        case .screenRecordingPermissionDenied:
            return "Grant Screen Recording permission in System Settings, quit and reopen the app, then try again."
        case .noDisplayAvailable:
            return "Connect or wake a display, then try again."
        case .unsupportedAudioFormat, .sampleBufferUnavailable:
            return "Try again. If this repeats, capture a Console log from the ComputerAudioCapture category."
        }
    }
}

struct ComputerAudioCaptureConfiguration: Sendable, Equatable {
    var sampleRate: Int
    var channelCount: Int
    var excludesCurrentProcessAudio: Bool

    nonisolated static let `default` = ComputerAudioCaptureConfiguration(
        sampleRate: 48_000,
        channelCount: 2,
        excludesCurrentProcessAudio: true
    )
}

@MainActor
final class ComputerAudioCaptureService: LiveAudioCaptureProvider {
    private let logger: Logger
    private let sampleHandlerQueue = DispatchQueue(label: "com.falsoai.lens.computer-audio-capture")
    private var stream: SCStream?
    private var streamOutput: ComputerAudioStreamOutput?

    private(set) var isRunning = false

    init(
        logger: Logger = Logger(
            subsystem: Bundle.main.bundleIdentifier ?? "com.falsoai.FalsoaiLens",
            category: "ComputerAudioCapture"
        )
    ) {
        self.logger = logger
    }

    func startCapture() async throws -> AsyncStream<CapturedAudioBuffer> {
        try await startCapture(configuration: .default)
    }

    func startCapture(
        configuration: ComputerAudioCaptureConfiguration = .default
    ) async throws -> AsyncStream<CapturedAudioBuffer> {
        guard !isRunning else {
            throw ComputerAudioCaptureError.alreadyRunning
        }
        guard CGPreflightScreenCaptureAccess() else {
            throw ComputerAudioCaptureError.screenRecordingPermissionDenied
        }

        let content = try await SCShareableContent.current
        guard let display = content.displays.first else {
            throw ComputerAudioCaptureError.noDisplayAvailable
        }

        let streamPair = AsyncStream<CapturedAudioBuffer>.makeStream(bufferingPolicy: .bufferingNewest(512))
        let streamOutput = ComputerAudioStreamOutput(
            continuation: streamPair.continuation,
            logger: logger
        )

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let streamConfiguration = SCStreamConfiguration()
        streamConfiguration.width = max(display.width, 2)
        streamConfiguration.height = max(display.height, 2)
        streamConfiguration.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        streamConfiguration.queueDepth = 3
        streamConfiguration.showsCursor = false
        streamConfiguration.capturesAudio = true
        streamConfiguration.captureMicrophone = false
        streamConfiguration.sampleRate = configuration.sampleRate
        streamConfiguration.channelCount = configuration.channelCount
        streamConfiguration.excludesCurrentProcessAudio = configuration.excludesCurrentProcessAudio

        let stream = SCStream(
            filter: filter,
            configuration: streamConfiguration,
            delegate: streamOutput
        )

        try stream.addStreamOutput(streamOutput, type: .audio, sampleHandlerQueue: sampleHandlerQueue)
        try stream.addStreamOutput(streamOutput, type: .screen, sampleHandlerQueue: sampleHandlerQueue)
        try await stream.startCapture()

        self.stream = stream
        self.streamOutput = streamOutput
        isRunning = true

        streamPair.continuation.onTermination = { [weak self] _ in
            Task { @MainActor in
                await self?.stopCapture()
            }
        }

        logger.info(
            "Computer audio capture started displayID=\(display.displayID, privacy: .public), sampleRate=\(configuration.sampleRate, privacy: .public), channels=\(configuration.channelCount, privacy: .public), excludesCurrentProcessAudio=\(configuration.excludesCurrentProcessAudio, privacy: .public)"
        )

        return streamPair.stream
    }

    func stopCapture() async {
        guard isRunning || stream != nil || streamOutput != nil else { return }

        let currentStream = stream
        let currentOutput = streamOutput
        stream = nil
        streamOutput = nil
        isRunning = false

        if let currentStream, let currentOutput {
            try? await currentStream.stopCapture()
            try? currentStream.removeStreamOutput(currentOutput, type: .audio)
            try? currentStream.removeStreamOutput(currentOutput, type: .screen)
        }

        currentOutput?.finish()
        logger.info("Computer audio capture stopped")
    }
}
```

- [ ] **Step 3: Add the private stream output class below `ComputerAudioCaptureService`**

In the same file:

```swift
private nonisolated final class ComputerAudioStreamOutput: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let continuation: AsyncStream<CapturedAudioBuffer>.Continuation
    private let logger: Logger

    init(
        continuation: AsyncStream<CapturedAudioBuffer>.Continuation,
        logger: Logger
    ) {
        self.continuation = continuation
        self.logger = logger
    }

    func finish() {
        continuation.finish()
    }

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        guard type == .audio, CMSampleBufferDataIsReady(sampleBuffer) else { return }

        do {
            let buffer = try ScreenCaptureAudioBufferReader.capturedAudioBuffer(from: sampleBuffer)
            continuation.yield(buffer)
        } catch {
            logger.error("Failed to copy computer audio sample buffer: \(String(describing: error), privacy: .public)")
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        logger.error("Computer audio stream stopped with error: \(String(describing: error), privacy: .public)")
        continuation.finish()
    }
}
```

- [ ] **Step 4: Verify computer capture does not mention microphone**

Run:

```bash
rg -n "microphone|captureMicrophone = true|AudioCaptureService" falsoai-lens/Pipelines/Hearing/Services/ComputerAudioCaptureService.swift
```

Expected:

```text
streamConfiguration.captureMicrophone = false
```

No `AudioCaptureService` references.

---

### Task 6: Create `LiveAudioTranscriptionPipeline`

**Files:**
- Create: `falsoai-lens/Pipelines/Hearing/Services/LiveAudioTranscriptionPipeline.swift`

- [ ] **Step 1: Create the single-source pipeline skeleton**

Create `falsoai-lens/Pipelines/Hearing/Services/LiveAudioTranscriptionPipeline.swift`:

```swift
import Combine
import Foundation
import OSLog

@MainActor
final class LiveAudioTranscriptionPipeline: ObservableObject {
    @Published private(set) var isRunning = false
    @Published private(set) var isProcessingChunk = false
    @Published private(set) var statusText: String
    @Published private(set) var errorMessage: String?
    @Published private(set) var transcript: SourceTranscriptState

    let source: CapturedAudioSource

    private let captureProvider: LiveAudioCaptureProvider
    private let chunker: AudioChunker?
    private let normalizer: AudioNormalizer?
    private let engine: TranscriptionEngine?
    private let logger: Logger
    private var captureTask: Task<Void, Never>?

    init(
        source: CapturedAudioSource,
        captureProvider: LiveAudioCaptureProvider,
        chunker: AudioChunker? = nil,
        normalizer: AudioNormalizer? = nil,
        engine: TranscriptionEngine? = nil,
        logger: Logger = Logger(
            subsystem: Bundle.main.bundleIdentifier ?? "com.falsoai.FalsoaiLens",
            category: "LiveAudioTranscription"
        )
    ) {
        self.source = source
        self.captureProvider = captureProvider
        self.logger = logger
        self.transcript = SourceTranscriptState(source: source)
        self.statusText = "\(source.displayName) transcription is stopped."

        if let chunker {
            self.chunker = chunker
        } else {
            self.chunker = try? AudioChunker(source: source)
        }

        if let normalizer {
            self.normalizer = normalizer
        } else {
            self.normalizer = try? AudioNormalizer()
        }

        if let engine {
            self.engine = engine
        } else {
            self.engine = Self.makeDefaultEngine(source: source, logger: logger)
        }

        if self.chunker == nil {
            errorMessage = "\(source.displayName) audio buffer could not be initialized."
        }
        if self.normalizer == nil {
            errorMessage = "\(source.displayName) audio normalizer could not be initialized."
        }
        if self.engine == nil {
            errorMessage = "\(source.displayName) Whisper engine unavailable."
        }
    }

    static func computer() -> LiveAudioTranscriptionPipeline {
        LiveAudioTranscriptionPipeline(
            source: .computer,
            captureProvider: ComputerAudioCaptureService()
        )
    }

    static func microphone() -> LiveAudioTranscriptionPipeline {
        LiveAudioTranscriptionPipeline(
            source: .microphone,
            captureProvider: MicrophoneAudioCaptureProvider()
        )
    }
}
```

- [ ] **Step 2: Add availability and lifecycle methods**

Inside `LiveAudioTranscriptionPipeline`:

```swift
var isAvailable: Bool {
    chunker != nil && normalizer != nil && engine != nil
}

func start(mode: TranscriptionMode) async {
    guard !isRunning else { return }
    guard let chunker, let normalizer, let engine else {
        errorMessage = errorMessage ?? "\(source.displayName) live transcription is not available."
        return
    }

    await chunker.clear()
    transcript = SourceTranscriptState(source: source)
    errorMessage = nil
    isProcessingChunk = false
    statusText = "Starting \(source.displayName.lowercased()) capture..."

    let stream: AsyncStream<CapturedAudioBuffer>
    do {
        stream = try await captureProvider.startCapture()
    } catch {
        errorMessage = Self.userFacingMessage(for: error)
        statusText = "\(source.displayName) transcription could not start."
        logger.error("Live \(source.rawValue, privacy: .public) capture failed to start: \(String(describing: error), privacy: .public)")
        return
    }

    isRunning = true
    statusText = "Listening to \(source.displayName.lowercased()) audio..."

    captureTask = Task.detached(priority: .userInitiated) { [weak self, chunker, normalizer, engine, stream, mode] in
        for await buffer in stream {
            if Task.isCancelled { break }

            do {
                let chunks = try await chunker.append(buffer)
                for chunk in chunks {
                    if Task.isCancelled { break }
                    await self?.transcribe(
                        chunk: chunk,
                        normalizer: normalizer,
                        engine: engine,
                        mode: mode
                    )
                }
            } catch {
                await self?.handleLiveError(error)
            }
        }

        await self?.handleCaptureStreamEnded()
    }

    logger.info("Live \(source.rawValue, privacy: .public) transcription started mode=\(String(describing: mode), privacy: .public)")
}

func stop() async {
    captureTask?.cancel()
    captureTask = nil
    await captureProvider.stopCapture()
    await chunker?.clear()

    isRunning = false
    isProcessingChunk = false
    statusText = transcript.chunksTranscribed > 0
        ? "Stopped \(source.displayName.lowercased()) after \(transcript.chunksTranscribed) transcript chunks."
        : "\(source.displayName) transcription is stopped."

    logger.info("Live \(self.source.rawValue, privacy: .public) transcription stopped chunks=\(self.transcript.chunksTranscribed, privacy: .public)")
}

func clearTranscript() {
    transcript = SourceTranscriptState(source: source)
    errorMessage = nil
    statusText = isRunning
        ? "Listening to \(source.displayName.lowercased()) audio..."
        : "\(source.displayName) transcription is stopped."
}
```

- [ ] **Step 3: Add single-source transcription helpers**

Inside `LiveAudioTranscriptionPipeline`:

```swift
private func transcribe(
    chunk: BufferedAudioChunk,
    normalizer: AudioNormalizer,
    engine: TranscriptionEngine,
    mode: TranscriptionMode
) async {
    isProcessingChunk = true
    statusText = "Transcribing recent \(source.displayName.lowercased()) audio..."

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
        append(result: result, elapsed: Date().timeIntervalSince(started))
    } catch {
        errorMessage = Self.userFacingMessage(for: error)
        logger.error("Live \(self.source.rawValue, privacy: .public) transcription error: \(String(describing: error), privacy: .public)")
    }

    isProcessingChunk = false
    if isRunning, errorMessage == nil {
        statusText = "Listening to \(source.displayName.lowercased()) audio..."
    }
}

private func append(result: TranscriptionResult, elapsed: Double) {
    transcript.lastInferenceDurationSeconds = elapsed

    let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else {
        statusText = "No voice detected in the latest \(source.displayName.lowercased()) audio window."
        return
    }

    transcript.text = Self.appendDeduplicating(
        existing: transcript.text,
        addition: text
    )
    transcript.chunksTranscribed += 1
    transcript.latestLanguage = result.language ?? transcript.latestLanguage
    errorMessage = nil

    logger.info(
        "Live \(self.source.rawValue, privacy: .public) transcription appended characters=\(text.count, privacy: .public), chunks=\(self.transcript.chunksTranscribed, privacy: .public), elapsedSeconds=\(elapsed, privacy: .public), language=\(result.language ?? "nil", privacy: .public)"
    )
}
```

- [ ] **Step 4: Add utility helpers**

Inside `LiveAudioTranscriptionPipeline`:

```swift
private func handleLiveError(_ error: Error) {
    errorMessage = Self.userFacingMessage(for: error)
    statusText = isRunning
        ? "\(source.displayName) transcription hit an error; listening continues."
        : "\(source.displayName) transcription is stopped."
    logger.error("Live \(self.source.rawValue, privacy: .public) transcription error: \(String(describing: error), privacy: .public)")
}

private func handleCaptureStreamEnded() async {
    guard isRunning else { return }
    isRunning = false
    isProcessingChunk = false
    captureTask = nil
    await captureProvider.stopCapture()
    statusText = "\(source.displayName) capture ended."
}

private nonisolated static func makeDefaultEngine(
    source: CapturedAudioSource,
    logger: Logger
) -> TranscriptionEngine? {
    do {
        return try WhisperCppEngine()
    } catch let error as WhisperEngineError {
        let message = error.errorDescription ?? "Whisper engine unavailable."
        let suggestion = error.recoverySuggestion ?? ""
        logger.error("Live \(source.rawValue, privacy: .public) pipeline could not construct engine: \(message, privacy: .public). \(suggestion, privacy: .public)")
        return nil
    } catch {
        logger.error("Live \(source.rawValue, privacy: .public) pipeline failed to construct engine: \(String(describing: error), privacy: .public)")
        return nil
    }
}

private nonisolated static func userFacingMessage(for error: Error) -> String {
    if let localizedError = error as? LocalizedError {
        let message = localizedError.errorDescription ?? error.localizedDescription
        let suggestion = localizedError.recoverySuggestion ?? ""
        return suggestion.isEmpty ? message : "\(message) \(suggestion)"
    }

    return error.localizedDescription
}

nonisolated static func appendDeduplicating(existing: String, addition: String) -> String {
    let trimmedAddition = addition.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedAddition.isEmpty else { return existing }

    let trimmedExisting = existing.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedExisting.isEmpty else { return trimmedAddition }
    guard trimmedExisting != trimmedAddition else { return trimmedExisting }

    let maxOverlapLength = min(160, trimmedExisting.count, trimmedAddition.count)
    if maxOverlapLength > 0 {
        for overlapLength in stride(from: maxOverlapLength, through: 1, by: -1) {
            let existingSuffix = String(trimmedExisting.suffix(overlapLength)).lowercased()
            let additionPrefix = String(trimmedAddition.prefix(overlapLength)).lowercased()

            if existingSuffix == additionPrefix {
                let dropIndex = trimmedAddition.index(
                    trimmedAddition.startIndex,
                    offsetBy: overlapLength
                )
                let remainder = String(trimmedAddition[dropIndex...])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return remainder.isEmpty
                    ? trimmedExisting
                    : "\(trimmedExisting) \(remainder)"
            }
        }
    }

    return "\(trimmedExisting) \(trimmedAddition)"
}
```

- [ ] **Step 5: Move `displayName` extension if needed**

If `CapturedAudioSource.displayName` currently lives only at the bottom of `LiveMixedAudioTranscriptionPipeline.swift`, move it into `LiveAudioTranscriptionPipeline.swift` or a model extension file:

```swift
extension CapturedAudioSource {
    var displayName: String {
        switch self {
        case .computer:
            return "Computer"
        case .microphone:
            return "Microphone"
        }
    }
}
```

- [ ] **Step 6: Verify the single-source pipeline has no cross-source terms**

Run:

```bash
rg -n "Mixed|SeparatedAudioChunkBatch|resolveSourceOwnership|isLikelySameUtterance|lastAcceptedText|computerTranscript|microphoneTranscript" falsoai-lens/Pipelines/Hearing/Services/LiveAudioTranscriptionPipeline.swift
```

Expected: no matches.

---

### Task 7: Rewire `ContentView` To Own Two Pipelines

**Files:**
- Modify: `falsoai-lens/ContentView.swift`

- [ ] **Step 1: Replace the mixed state object**

Replace:

```swift
@StateObject private var liveHearing = LiveMixedAudioTranscriptionPipeline()
```

With:

```swift
@StateObject private var computerHearing = LiveAudioTranscriptionPipeline.computer()
@StateObject private var microphoneHearing = LiveAudioTranscriptionPipeline.microphone()
```

- [ ] **Step 2: Add view-level combined control helpers**

Inside `ContentView`, add:

```swift
private var isLiveAudioRunning: Bool {
    computerHearing.isRunning || microphoneHearing.isRunning
}

private var isLiveAudioProcessing: Bool {
    computerHearing.isProcessingChunk || microphoneHearing.isProcessingChunk
}

private var isLiveAudioAvailable: Bool {
    computerHearing.isAvailable && microphoneHearing.isAvailable
}

private var hasLiveTranscriptText: Bool {
    !computerHearing.transcript.isEmpty || !microphoneHearing.transcript.isEmpty
}

private func startLiveAudioPipelines() async {
    await computerHearing.start(mode: hearingMode)
    await microphoneHearing.start(mode: hearingMode)
}

private func stopLiveAudioPipelines() async {
    await computerHearing.stop()
    await microphoneHearing.stop()
}

private func clearLiveAudioTranscripts() {
    computerHearing.clearTranscript()
    microphoneHearing.clearTranscript()
}
```

- [ ] **Step 3: Replace the start/stop button action**

Replace references to `liveHearing.isRunning`, `liveHearing.start`, and `liveHearing.stop` with the new helpers:

```swift
Button {
    Task {
        if isLiveAudioRunning {
            await stopLiveAudioPipelines()
        } else {
            await startLiveAudioPipelines()
        }
    }
} label: {
    Label(
        isLiveAudioRunning ? "Stop Capture" : "Start Capture",
        systemImage: isLiveAudioRunning ? "stop.circle" : "record.circle"
    )
}
.disabled(!isLiveAudioAvailable && !isLiveAudioRunning)
```

- [ ] **Step 4: Replace clear button and header counts**

Use the two independent transcripts:

```swift
if hasLiveTranscriptText {
    Text("Computer \(computerHearing.transcript.chunksTranscribed) | Mic \(microphoneHearing.transcript.chunksTranscribed)")
        .font(.caption)
        .foregroundStyle(.secondary)
}
```

And:

```swift
Button {
    clearLiveAudioTranscripts()
} label: {
    Label("Clear Both", systemImage: "trash")
}
.disabled(!hasLiveTranscriptText && computerHearing.errorMessage == nil && microphoneHearing.errorMessage == nil)
```

- [ ] **Step 5: Replace status row**

Show independent statuses:

```swift
VStack(alignment: .leading, spacing: 4) {
    Label(computerHearing.statusText, systemImage: computerHearing.isRunning ? "waveform" : "waveform.slash")
    Label(microphoneHearing.statusText, systemImage: microphoneHearing.isRunning ? "waveform" : "waveform.slash")
}
.font(.callout)
.foregroundStyle(.secondary)

if isLiveAudioProcessing {
    ProgressView()
        .controlSize(.small)
}
```

- [ ] **Step 6: Pass independent transcripts into panels**

Replace:

```swift
state: liveHearing.computerTranscript
...
copyToPasteboard(liveHearing.computerTranscript.text)
...
state: liveHearing.microphoneTranscript
...
copyToPasteboard(liveHearing.microphoneTranscript.text)
```

With:

```swift
state: computerHearing.transcript
...
copyToPasteboard(computerHearing.transcript.text)
...
state: microphoneHearing.transcript
...
copyToPasteboard(microphoneHearing.transcript.text)
```

- [ ] **Step 7: Show source-specific errors**

Replace the single `liveHearing.errorMessage` block with:

```swift
if let computerError = computerHearing.errorMessage {
    Text("Computer: \(computerError)")
        .font(.callout)
        .foregroundStyle(.red)
        .textSelection(.enabled)
}

if let microphoneError = microphoneHearing.errorMessage {
    Text("Microphone: \(microphoneError)")
        .font(.callout)
        .foregroundStyle(.red)
        .textSelection(.enabled)
}
```

- [ ] **Step 8: Verify `ContentView` no longer references the mixed pipeline**

Run:

```bash
rg -n "liveHearing|LiveMixedAudioTranscriptionPipeline|computerTranscript|microphoneTranscript|combinedTranscriptText" falsoai-lens/ContentView.swift
```

Expected after this task: no matches.

---

### Task 8: Retire Mixed Path From The UI Surface

**Files:**
- Inspect: `falsoai-lens/Pipelines/Hearing/Services/LiveMixedAudioTranscriptionPipeline.swift`
- Inspect: `falsoai-lens/Pipelines/Hearing/Services/MixedAudioBufferStore.swift`
- Inspect: `falsoai-lens/Pipelines/Hearing/Services/ComputerMicrophoneAudioCaptureService.swift`

- [ ] **Step 1: Verify old mixed types are no longer used**

Run:

```bash
rg -n "LiveMixedAudioTranscriptionPipeline|ComputerMicrophoneAudioCaptureService|MixedAudioBufferStore|SeparatedAudioChunkBatch" falsoai-lens --glob '*.swift'
```

Expected after `ContentView` rewiring: matches only in their own declarations and any debug smoke checks, not in `ContentView.swift` or the new `LiveAudioTranscriptionPipeline.swift`.

- [ ] **Step 2: Do not delete old mixed files in this first implementation pass**

Reason:

```text
This plan changes runtime behavior by removing mixed services from the UI. Deleting the old files can be a follow-up cleanup after manual verification confirms the two independent pipelines behave correctly.
```

This keeps the implementation focused and avoids mixing a behavior change with a large deletion/refactor.

---

### Task 9: Build Verification

**Files:**
- Build all Swift sources.

- [ ] **Step 1: Run the debug build**

Run:

```bash
xcodebuild -project falsoai-lens.xcodeproj -scheme falsoai-lens -configuration Debug build
```

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 2: Verify forbidden mixed references in `ContentView` and new pipeline**

Run:

```bash
rg -n "LiveMixedAudioTranscriptionPipeline|ComputerMicrophoneAudioCaptureService|MixedAudioBufferStore|SeparatedAudioChunkBatch|resolveSourceOwnership|isLikelySameUtterance|lastAcceptedText" falsoai-lens/ContentView.swift falsoai-lens/Pipelines/Hearing/Services/LiveAudioTranscriptionPipeline.swift
```

Expected: no matches.

---

### Task 10: Manual Runtime Verification

**Files:**
- Runtime verification in the macOS app.

- [ ] **Step 1: Start capture**

Launch from Xcode and click `Start Capture`.

Expected:

```text
Computer pipeline status changes independently.
Microphone pipeline status changes independently.
One failing source reports its own error without rewriting the other source's transcript.
```

- [ ] **Step 2: Speak while computer audio is silent**

Expected:

```text
Microphone panel receives microphone transcript text.
Computer panel stays empty unless ScreenCaptureKit computer audio truly contains that signal.
No code promotes computer text into microphone text.
No code suppresses computer text because microphone text exists.
```

- [ ] **Step 3: Play computer audio while silent**

Expected:

```text
Computer panel receives computer transcript text.
Microphone panel stays empty unless the physical microphone hears the speaker output.
No code moves microphone text into computer text.
No code suppresses microphone text because computer text exists.
```

- [ ] **Step 4: Speak while computer audio plays**

Expected:

```text
Both panels update independently from their own capture providers.
Similar or duplicated text may appear in both panels if both physical/capture paths genuinely heard similar audio.
That duplication is allowed and must not be hidden by transcript-layer arbitration.
```

---

## Self-Review

Spec coverage:

- Creates one computer audio pipeline: Task 5 creates `ComputerAudioCaptureService`; Task 6 creates `LiveAudioTranscriptionPipeline`; Task 7 instantiates `.computer()`.
- Creates one microphone audio pipeline: Task 4 creates `MicrophoneAudioCaptureProvider`; Task 6 creates `LiveAudioTranscriptionPipeline`; Task 7 instantiates `.microphone()`.
- Does not mix sources: Task 6 forbids mixed/batch/cross-source logic in the new pipeline; Task 7 removes `LiveMixedAudioTranscriptionPipeline` from `ContentView`.
- Keeps UI separate: Task 7 feeds `computerHearing.transcript` and `microphoneHearing.transcript` into separate panels.
- Preserves concurrency: Task 7 starts both pipelines; each pipeline has its own capture task, chunker, normalizer, and engine.
- Build verification: Task 9 runs `xcodebuild`.
- Runtime verification: Task 10 checks both source-specific scenarios.

Placeholder scan:

- No `TBD`, `TODO`, or “implement later” steps remain.
- The only “move existing implementation unchanged” instruction is anchored to an existing concrete method in `ComputerMicrophoneAudioCaptureService.swift`; the worker must move that code exactly, not invent a new parser.

Type consistency:

- `LiveAudioTranscriptionPipeline` exposes `transcript`, not `computerTranscript` or `microphoneTranscript`.
- `ContentView` owns `computerHearing` and `microphoneHearing`.
- `AudioChunker(source:)` and `AudioBufferStore(source:)` agree on `CapturedAudioSource`.
