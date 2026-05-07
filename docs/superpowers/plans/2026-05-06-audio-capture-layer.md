# Audio Capture Layer Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the first Hearing pipeline layer: a focused `AVAudioEngine` microphone capture service that starts/stops capture and emits copied, Sendable audio buffers for the future buffer/chunking layer.

**Architecture:** Add the Hearing pipeline under `falsoai-lens/Pipelines/Hearing`. Keep this layer responsible only for microphone capture, permission preflight, tap lifecycle, and raw sample delivery. Do not implement rolling buffers, chunking, WAV normalization, Whisper execution, transcript assembly, or UI in this plan.

**Tech Stack:** Swift, AVFoundation, CoreMedia, OSLog, Swift concurrency, macOS microphone entitlement already configured.

---

## Assumptions

- The current doc source of truth is `docs/Live Audio Transcriber Architecture.md`, especially section `4.1 Audio Capture Layer`.
- The project has `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, so the service will be `@MainActor` for engine lifecycle state.
- `AVAudioEngine` tap callbacks do not run on the main actor. The tap must do minimal work: copy buffer samples into a Sendable value and yield it.
- The app already has `NSMicrophoneUsageDescription` and `com.apple.security.device.audio-input`.
- There is no test target yet, so verification for this layer is build-based until a UI/manual smoke path is added.

## File Structure

- Create `falsoai-lens/Pipelines/Hearing/Models/CapturedAudioBuffer.swift`
  - Defines the Sendable value emitted by the capture layer.
  - Copies float PCM samples out of `AVAudioPCMBuffer`.
  - Stores format metadata needed by the future buffer/chunking layer.
- Create `falsoai-lens/Pipelines/Hearing/Services/AudioCaptureService.swift`
  - Owns `AVAudioEngine`.
  - Checks microphone authorization.
  - Installs/removes input tap.
  - Starts/stops capture.
  - Exposes `AsyncStream<CapturedAudioBuffer>` for downstream layers.
- Create `falsoai-lens/Dependencies/Hearing/HearingDependencies.swift`
  - Records the Apple framework dependency used by the Hearing pipeline.
- Modify `falsoai-lens/Dependencies/DependencyImports.swift`
  - Keep the dependency sentinel aware of the Hearing pipeline.

No Xcode project file edits are needed because `falsoai-lens/` is a file-system synchronized group.

---

### Task 1: Add Hearing Dependency Descriptor

**Files:**
- Create: `falsoai-lens/Dependencies/Hearing/HearingDependencies.swift`
- Modify: `falsoai-lens/Dependencies/DependencyImports.swift`

- [ ] **Step 1: Create the Hearing dependency folder and file**

Create `falsoai-lens/Dependencies/Hearing/HearingDependencies.swift`:

```swift
import AVFoundation

enum HearingDependencies {
    static let captureEngineType = AVAudioEngine.self
    static let microphoneMediaType = AVMediaType.audio
}
```

- [ ] **Step 2: Add the import sentinel**

Update `falsoai-lens/Dependencies/DependencyImports.swift` to keep `AVFoundation` present for the Hearing pipeline:

```swift
import SwiftUI
import Vision
import ScreenCaptureKit
import AVFoundation
import UserNotifications
import SwiftData
import GRDB
import AppKit
import UniformTypeIdentifiers
import ApplicationServices

enum DependencyImports {
    static let configured = true
    static let hearingConfigured = HearingDependencies.captureEngineType == AVAudioEngine.self
}
```

- [ ] **Step 3: Build-check dependency descriptor**

Run:

```bash
xcodebuild -project falsoai-lens.xcodeproj -scheme falsoai-lens -configuration Debug build
```

Expected: build succeeds.

---

### Task 2: Define the Captured Audio Buffer Value

**Files:**
- Create: `falsoai-lens/Pipelines/Hearing/Models/CapturedAudioBuffer.swift`

- [ ] **Step 1: Create the Sendable audio buffer model**

Create `falsoai-lens/Pipelines/Hearing/Models/CapturedAudioBuffer.swift`:

```swift
import AVFoundation
import CoreMedia
import Foundation

struct CapturedAudioBuffer: Sendable, Equatable {
    let samples: [Float]
    let sampleRate: Double
    let channelCount: Int
    let frameCount: Int
    let hostTime: UInt64

    var duration: TimeInterval {
        guard sampleRate > 0 else { return 0 }
        return Double(frameCount) / sampleRate
    }

    init(
        samples: [Float],
        sampleRate: Double,
        channelCount: Int,
        frameCount: Int,
        hostTime: UInt64
    ) {
        self.samples = samples
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.frameCount = frameCount
        self.hostTime = hostTime
    }

    init(copying buffer: AVAudioPCMBuffer, at time: AVAudioTime) {
        let frameCount = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        var copiedSamples: [Float] = []
        copiedSamples.reserveCapacity(frameCount * max(channelCount, 1))

        if let channelData = buffer.floatChannelData {
            for frameIndex in 0..<frameCount {
                for channelIndex in 0..<channelCount {
                    copiedSamples.append(channelData[channelIndex][frameIndex])
                }
            }
        }

        self.init(
            samples: copiedSamples,
            sampleRate: buffer.format.sampleRate,
            channelCount: channelCount,
            frameCount: frameCount,
            hostTime: time.hostTime
        )
    }
}
```

- [ ] **Step 2: Build-check model**

Run:

```bash
xcodebuild -project falsoai-lens.xcodeproj -scheme falsoai-lens -configuration Debug build
```

Expected: build succeeds.

---

### Task 3: Implement Audio Capture Service

**Files:**
- Create: `falsoai-lens/Pipelines/Hearing/Services/AudioCaptureService.swift`

- [ ] **Step 1: Create the service file**

Create `falsoai-lens/Pipelines/Hearing/Services/AudioCaptureService.swift`:

```swift
import AVFoundation
import Foundation
import OSLog

enum AudioCaptureError: LocalizedError, Equatable {
    case microphonePermissionDenied
    case microphonePermissionNotDetermined
    case inputFormatUnavailable
    case alreadyRunning

    var errorDescription: String? {
        switch self {
        case .microphonePermissionDenied:
            return "Microphone permission is denied for Falsoai Lens."
        case .microphonePermissionNotDetermined:
            return "Microphone permission has not been requested yet."
        case .inputFormatUnavailable:
            return "The microphone input format was unavailable."
        case .alreadyRunning:
            return "Audio capture is already running."
        }
    }

    var recoverySuggestion: String? {
        switch self {
        case .microphonePermissionDenied:
            return "Grant Microphone access in System Settings, then try again."
        case .microphonePermissionNotDetermined:
            return "Request Microphone access before starting audio capture."
        case .inputFormatUnavailable:
            return "Check that a microphone is connected and available."
        case .alreadyRunning:
            return "Stop the current capture before starting another one."
        }
    }
}

struct AudioCaptureConfiguration: Sendable, Equatable {
    var inputBus: AVAudioNodeBus
    var bufferSize: AVAudioFrameCount

    nonisolated static let `default` = AudioCaptureConfiguration(
        inputBus: 0,
        bufferSize: 1024
    )
}

@MainActor
final class AudioCaptureService {
    private let engine: AVAudioEngine
    private let logger: Logger
    private var continuation: AsyncStream<CapturedAudioBuffer>.Continuation?
    private var inputBus: AVAudioNodeBus = AudioCaptureConfiguration.default.inputBus

    private(set) var isRunning = false

    init(
        engine: AVAudioEngine = AVAudioEngine(),
        logger: Logger = Logger(
            subsystem: Bundle.main.bundleIdentifier ?? "com.falsoai.FalsoaiLens",
            category: "AudioCapture"
        )
    ) {
        self.engine = engine
        self.logger = logger
    }

    func startCapture(
        configuration: AudioCaptureConfiguration = .default
    ) throws -> AsyncStream<CapturedAudioBuffer> {
        guard !isRunning else {
            throw AudioCaptureError.alreadyRunning
        }

        try prepareForCapture()

        let inputNode = engine.inputNode
        let format = inputNode.outputFormat(forBus: configuration.inputBus)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw AudioCaptureError.inputFormatUnavailable
        }

        let streamPair = AsyncStream<CapturedAudioBuffer>.makeStream()
        continuation = streamPair.continuation
        inputBus = configuration.inputBus

        let streamContinuation = streamPair.continuation
        inputNode.installTap(
            onBus: configuration.inputBus,
            bufferSize: configuration.bufferSize,
            format: format
        ) { buffer, time in
            let capturedBuffer = CapturedAudioBuffer(copying: buffer, at: time)
            streamContinuation.yield(capturedBuffer)
        }

        engine.prepare()
        try engine.start()
        isRunning = true

        logger.info(
            "Audio capture started sampleRate=\(format.sampleRate, privacy: .public), channels=\(format.channelCount, privacy: .public), bufferSize=\(configuration.bufferSize, privacy: .public)"
        )

        return streamPair.stream
    }

    func stopCapture() {
        guard isRunning || continuation != nil else { return }

        engine.inputNode.removeTap(onBus: inputBus)
        engine.stop()
        continuation?.finish()
        continuation = nil
        inputBus = AudioCaptureConfiguration.default.inputBus
        isRunning = false

        logger.info("Audio capture stopped")
    }

    private func prepareForCapture() throws {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return
        case .denied, .restricted:
            throw AudioCaptureError.microphonePermissionDenied
        case .notDetermined:
            throw AudioCaptureError.microphonePermissionNotDetermined
        @unknown default:
            throw AudioCaptureError.microphonePermissionDenied
        }
    }
}
```

- [ ] **Step 2: Build-check the service**

Run:

```bash
xcodebuild -project falsoai-lens.xcodeproj -scheme falsoai-lens -configuration Debug build
```

Expected: build succeeds.

---

### Task 4: Add Minimal Capture Lifecycle Notes To The Architecture Doc

**Files:**
- Modify: `docs/Live Audio Transcriber Architecture.md`

- [ ] **Step 1: Add an implementation note under `4.1 Audio Capture Layer`**

Add this note after the existing `Notes` paragraph in section `4.1 Audio Capture Layer`:

```markdown
### Implementation Boundary

The app implementation keeps this layer focused on microphone capture only. It starts and stops `AVAudioEngine`, installs one input tap, checks microphone permission state, and emits copied audio sample buffers to the next layer. It does not chunk, normalize, write WAV files, invoke Whisper, or update SwiftUI directly.
```

- [ ] **Step 2: Build is not needed for doc-only change**

Run:

```bash
git diff --check -- 'docs/Live Audio Transcriber Architecture.md'
```

Expected: no output and exit code 0.

---

### Task 5: Final Verification

**Files:**
- Verify all files touched in this plan.

- [ ] **Step 1: Check formatting whitespace**

Run:

```bash
git diff --check -- falsoai-lens/Pipelines/Hearing falsoai-lens/Dependencies/Hearing falsoai-lens/Dependencies/DependencyImports.swift 'docs/Live Audio Transcriber Architecture.md'
```

Expected: no output and exit code 0.

- [ ] **Step 2: Build the app**

Run:

```bash
xcodebuild -project falsoai-lens.xcodeproj -scheme falsoai-lens -configuration Debug build
```

Expected: build succeeds.

- [ ] **Step 3: Confirm scope stayed within Audio Capture Layer**

Run:

```bash
git diff --stat
```

Expected: changes are limited to:

```text
docs/Live Audio Transcriber Architecture.md
falsoai-lens/Dependencies/DependencyImports.swift
falsoai-lens/Dependencies/Hearing/HearingDependencies.swift
falsoai-lens/Pipelines/Hearing/Models/CapturedAudioBuffer.swift
falsoai-lens/Pipelines/Hearing/Services/AudioCaptureService.swift
```

If UI, chunking, WAV writing, Whisper, or transcript files appear in the diff, stop and remove those changes from this layer.

---

## Open Question Before Execution

Should the first execution include a tiny temporary UI/manual smoke hook in `ContentView` to start/stop capture and display buffer counts, or should this first layer remain service-only until the later SwiftUI Presentation Layer?

Recommended: keep this first layer service-only, then add a small UI hook when the buffer/chunking layer exists.
