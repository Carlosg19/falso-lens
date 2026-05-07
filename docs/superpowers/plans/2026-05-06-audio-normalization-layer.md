# Audio Normalization Layer Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the Hearing pipeline's Audio Normalization Layer: convert raw `BufferedAudioChunk` values into 16 kHz mono PCM WAV files that `whisper-cli` can consume.

**Architecture:** Keep normalization separate from inference. `AudioNormalizer` will downmix interleaved float chunks to mono, resample to the Whisper target rate, and delegate WAV serialization to `WAVWriter`. The output is a `NormalizedAudioChunk` containing normalized PCM samples plus the temporary `.wav` file URL; this layer does not invoke Whisper, parse transcripts, deduplicate text, or update SwiftUI.

**Tech Stack:** Swift, Foundation, Swift actors, Sendable value types, manual PCM WAV serialization, existing `BufferedAudioChunk`.

---

## Assumptions

- The current doc source of truth is `docs/Live Audio Transcriber Architecture.md`, especially section `4.4 Audio Normalization Layer`.
- The input `BufferedAudioChunk.samples` array is interleaved by frame: frame 0 channel 0, frame 0 channel 1, frame 1 channel 0, etc.
- The MVP output should be a temporary WAV file because `whisper.cpp` CLI accepts file paths directly.
- The target format for the MVP is 16 kHz, mono, signed 16-bit PCM WAV.
- Resampling uses a small linear interpolation implementation for this MVP. If audio quality becomes an issue later, replace only the resampling helper with `AVAudioConverter` while preserving the same public API.
- There is no test target configured yet, so verification is build-based until a test target exists.

## File Structure

- Create `falsoai-lens/Pipelines/Hearing/Models/AudioNormalizationConfiguration.swift`
  - Defines the target sample rate, target channel count, output directory, and configuration validation.
  - Provides the MVP default: 16 kHz mono files under the system temp directory at `live-transcriber/`.
  - Defines `AudioNormalizationError` shared by the normalizer and WAV writer.
- Create `falsoai-lens/Pipelines/Hearing/Models/NormalizedAudioChunk.swift`
  - Defines normalized mono PCM samples and optional file URL metadata.
  - Keeps sequence number and start frame from the original chunk for downstream transcript alignment.
- Create `falsoai-lens/Pipelines/Hearing/Services/WAVWriter.swift`
  - Actor that writes a `NormalizedAudioChunk` to a signed 16-bit little-endian PCM WAV file.
  - Owns temporary directory creation and deterministic file naming.
- Create `falsoai-lens/Pipelines/Hearing/Services/AudioNormalizer.swift`
  - Actor that validates chunk layout, downmixes to mono, resamples to 16 kHz, creates a `NormalizedAudioChunk`, and optionally writes it to a temporary WAV file.
- Modify `docs/Live Audio Transcriber Architecture.md`
  - Add an implementation boundary note under `4.4 Audio Normalization Layer`.

No Xcode project file edits are needed because `falsoai-lens/` is a file-system synchronized group.

---

### Task 1: Add Normalization Configuration

**Files:**
- Create: `falsoai-lens/Pipelines/Hearing/Models/AudioNormalizationConfiguration.swift`

- [x] **Step 1: Create the configuration and error model**

Create `falsoai-lens/Pipelines/Hearing/Models/AudioNormalizationConfiguration.swift`:

```swift
import Foundation

enum AudioNormalizationError: LocalizedError, Equatable {
    case invalidConfiguration(targetSampleRate: Double, targetChannelCount: Int)
    case invalidChunkFormat(sampleRate: Double, channelCount: Int, frameCount: Int)
    case invalidChunkLayout(expectedSamples: Int, actualSamples: Int)
    case wavDataTooLarge(sampleCount: Int)

    var errorDescription: String? {
        switch self {
        case let .invalidConfiguration(targetSampleRate, targetChannelCount):
            return "Audio normalization configuration is invalid. Target sample rate \(targetSampleRate) Hz must be positive and target channel count \(targetChannelCount) must be 1."
        case let .invalidChunkFormat(sampleRate, channelCount, frameCount):
            return "Audio chunk format is invalid. Sample rate \(sampleRate) Hz, channel count \(channelCount), and frame count \(frameCount) must all be positive."
        case let .invalidChunkLayout(expectedSamples, actualSamples):
            return "Audio chunk sample layout is invalid. Expected \(expectedSamples) samples, got \(actualSamples)."
        case let .wavDataTooLarge(sampleCount):
            return "Audio chunk has \(sampleCount) samples, which is too large to write as one PCM WAV file."
        }
    }
}

struct AudioNormalizationConfiguration: Sendable, Equatable {
    var targetSampleRate: Double
    var targetChannelCount: Int
    var outputDirectory: URL

    nonisolated static let whisperMVP = AudioNormalizationConfiguration(
        targetSampleRate: 16_000,
        targetChannelCount: 1,
        outputDirectory: URL(
            fileURLWithPath: NSTemporaryDirectory(),
            isDirectory: true
        ).appendingPathComponent("live-transcriber", isDirectory: true)
    )

    nonisolated func validate() throws {
        guard targetSampleRate > 0, targetChannelCount == 1 else {
            throw AudioNormalizationError.invalidConfiguration(
                targetSampleRate: targetSampleRate,
                targetChannelCount: targetChannelCount
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

### Task 2: Add Normalized Audio Chunk Model

**Files:**
- Create: `falsoai-lens/Pipelines/Hearing/Models/NormalizedAudioChunk.swift`

- [x] **Step 1: Create the normalized chunk model**

Create `falsoai-lens/Pipelines/Hearing/Models/NormalizedAudioChunk.swift`:

```swift
import Foundation

struct NormalizedAudioChunk: Sendable, Equatable {
    let sequenceNumber: Int
    let startFrame: Int64
    let samples: [Float]
    let sampleRate: Double
    let channelCount: Int
    let sourceSampleRate: Double
    let sourceChannelCount: Int
    let fileURL: URL?

    nonisolated var frameCount: Int {
        samples.count
    }

    nonisolated var duration: TimeInterval {
        guard sampleRate > 0 else { return 0 }
        return Double(frameCount) / sampleRate
    }

    nonisolated func withFileURL(_ fileURL: URL) -> NormalizedAudioChunk {
        NormalizedAudioChunk(
            sequenceNumber: sequenceNumber,
            startFrame: startFrame,
            samples: samples,
            sampleRate: sampleRate,
            channelCount: channelCount,
            sourceSampleRate: sourceSampleRate,
            sourceChannelCount: sourceChannelCount,
            fileURL: fileURL
        )
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

### Task 3: Add PCM WAV Writer

**Files:**
- Create: `falsoai-lens/Pipelines/Hearing/Services/WAVWriter.swift`

- [x] **Step 1: Create the WAV writer actor**

Create `falsoai-lens/Pipelines/Hearing/Services/WAVWriter.swift`:

```swift
import Foundation

actor WAVWriter {
    private let outputDirectory: URL

    init(outputDirectory: URL = AudioNormalizationConfiguration.whisperMVP.outputDirectory) {
        self.outputDirectory = outputDirectory
    }

    func write(_ chunk: NormalizedAudioChunk) throws -> URL {
        try FileManager.default.createDirectory(
            at: outputDirectory,
            withIntermediateDirectories: true
        )

        let fileURL = outputDirectory.appendingPathComponent(
            String(format: "chunk-%04d.wav", chunk.sequenceNumber)
        )
        let wavData = try Self.wavData(for: chunk)
        try wavData.write(to: fileURL, options: [.atomic])
        return fileURL
    }

    private nonisolated static func wavData(for chunk: NormalizedAudioChunk) throws -> Data {
        let bytesPerSample = 2
        let dataByteCount = chunk.samples.count * bytesPerSample
        guard dataByteCount <= Int(UInt32.max) else {
            throw AudioNormalizationError.wavDataTooLarge(sampleCount: chunk.samples.count)
        }

        let sampleRate = UInt32(chunk.sampleRate.rounded(.toNearestOrAwayFromZero))
        let channelCount = UInt16(chunk.channelCount)
        let bitsPerSample: UInt16 = 16
        let blockAlign = channelCount * bitsPerSample / 8
        let byteRate = sampleRate * UInt32(blockAlign)
        let dataSize = UInt32(dataByteCount)
        let riffSize = UInt32(36) + dataSize

        var data = Data()
        data.reserveCapacity(44 + dataByteCount)

        appendASCII("RIFF", to: &data)
        appendUInt32(riffSize, to: &data)
        appendASCII("WAVE", to: &data)
        appendASCII("fmt ", to: &data)
        appendUInt32(16, to: &data)
        appendUInt16(1, to: &data)
        appendUInt16(channelCount, to: &data)
        appendUInt32(sampleRate, to: &data)
        appendUInt32(byteRate, to: &data)
        appendUInt16(blockAlign, to: &data)
        appendUInt16(bitsPerSample, to: &data)
        appendASCII("data", to: &data)
        appendUInt32(dataSize, to: &data)

        for sample in chunk.samples {
            let clampedSample = min(max(sample, -1), 1)
            let scaledSample = clampedSample < 0
                ? clampedSample * 32_768
                : clampedSample * 32_767
            appendInt16(Int16(scaledSample.rounded()), to: &data)
        }

        return data
    }

    private nonisolated static func appendASCII(_ value: String, to data: inout Data) {
        data.append(contentsOf: value.utf8)
    }

    private nonisolated static func appendUInt16(_ value: UInt16, to data: inout Data) {
        var littleEndianValue = value.littleEndian
        withUnsafeBytes(of: &littleEndianValue) { buffer in
            data.append(contentsOf: buffer)
        }
    }

    private nonisolated static func appendUInt32(_ value: UInt32, to data: inout Data) {
        var littleEndianValue = value.littleEndian
        withUnsafeBytes(of: &littleEndianValue) { buffer in
            data.append(contentsOf: buffer)
        }
    }

    private nonisolated static func appendInt16(_ value: Int16, to data: inout Data) {
        var littleEndianValue = value.littleEndian
        withUnsafeBytes(of: &littleEndianValue) { buffer in
            data.append(contentsOf: buffer)
        }
    }
}
```

- [x] **Step 2: Build-check the WAV writer**

Run:

```bash
xcodebuild -project falsoai-lens.xcodeproj -scheme falsoai-lens -configuration Debug build
```

Expected: build succeeds.

---

### Task 4: Add Audio Normalizer Actor

**Files:**
- Create: `falsoai-lens/Pipelines/Hearing/Services/AudioNormalizer.swift`

- [x] **Step 1: Create the normalizer actor**

Create `falsoai-lens/Pipelines/Hearing/Services/AudioNormalizer.swift`:

```swift
import Foundation

actor AudioNormalizer {
    private let configuration: AudioNormalizationConfiguration
    private let wavWriter: WAVWriter

    init(
        configuration: AudioNormalizationConfiguration = .whisperMVP,
        wavWriter: WAVWriter? = nil
    ) throws {
        try configuration.validate()
        self.configuration = configuration
        self.wavWriter = wavWriter ?? WAVWriter(outputDirectory: configuration.outputDirectory)
    }

    func normalize(_ chunk: BufferedAudioChunk) throws -> NormalizedAudioChunk {
        let monoSamples = try Self.downmixToMono(chunk)
        let normalizedSamples = Self.resampleMono(
            monoSamples,
            sourceSampleRate: chunk.sampleRate,
            targetSampleRate: configuration.targetSampleRate
        )

        return NormalizedAudioChunk(
            sequenceNumber: chunk.sequenceNumber,
            startFrame: chunk.startFrame,
            samples: normalizedSamples,
            sampleRate: configuration.targetSampleRate,
            channelCount: configuration.targetChannelCount,
            sourceSampleRate: chunk.sampleRate,
            sourceChannelCount: chunk.channelCount,
            fileURL: nil
        )
    }

    func normalizeToTemporaryWAV(_ chunk: BufferedAudioChunk) async throws -> NormalizedAudioChunk {
        let normalizedChunk = try normalize(chunk)
        let fileURL = try await wavWriter.write(normalizedChunk)
        return normalizedChunk.withFileURL(fileURL)
    }

    private nonisolated static func downmixToMono(_ chunk: BufferedAudioChunk) throws -> [Float] {
        guard chunk.sampleRate > 0, chunk.channelCount > 0, chunk.frameCount > 0 else {
            throw AudioNormalizationError.invalidChunkFormat(
                sampleRate: chunk.sampleRate,
                channelCount: chunk.channelCount,
                frameCount: chunk.frameCount
            )
        }

        let expectedSamples = chunk.frameCount * chunk.channelCount
        guard chunk.samples.count == expectedSamples else {
            throw AudioNormalizationError.invalidChunkLayout(
                expectedSamples: expectedSamples,
                actualSamples: chunk.samples.count
            )
        }

        guard chunk.channelCount > 1 else {
            return chunk.samples
        }

        var monoSamples: [Float] = []
        monoSamples.reserveCapacity(chunk.frameCount)

        for frameIndex in 0..<chunk.frameCount {
            let frameStartIndex = frameIndex * chunk.channelCount
            var frameTotal: Float = 0

            for channelIndex in 0..<chunk.channelCount {
                frameTotal += chunk.samples[frameStartIndex + channelIndex]
            }

            monoSamples.append(frameTotal / Float(chunk.channelCount))
        }

        return monoSamples
    }

    private nonisolated static func resampleMono(
        _ samples: [Float],
        sourceSampleRate: Double,
        targetSampleRate: Double
    ) -> [Float] {
        guard !samples.isEmpty, sourceSampleRate > 0, targetSampleRate > 0 else {
            return []
        }

        guard sourceSampleRate != targetSampleRate else {
            return samples
        }

        let sampleRateRatio = targetSampleRate / sourceSampleRate
        let outputSampleCount = max(
            1,
            Int((Double(samples.count) * sampleRateRatio).rounded(.toNearestOrAwayFromZero))
        )

        var outputSamples: [Float] = []
        outputSamples.reserveCapacity(outputSampleCount)

        for outputIndex in 0..<outputSampleCount {
            let sourcePosition = Double(outputIndex) / sampleRateRatio
            let lowerIndex = min(Int(sourcePosition.rounded(.down)), samples.count - 1)
            let upperIndex = min(lowerIndex + 1, samples.count - 1)
            let interpolationAmount = Float(sourcePosition - Double(lowerIndex))
            let lowerSample = samples[lowerIndex]
            let upperSample = samples[upperIndex]

            outputSamples.append(
                lowerSample + ((upperSample - lowerSample) * interpolationAmount)
            )
        }

        return outputSamples
    }
}
```

- [x] **Step 2: Build-check the normalizer**

Run:

```bash
xcodebuild -project falsoai-lens.xcodeproj -scheme falsoai-lens -configuration Debug build
```

Expected: build succeeds.

---

### Task 5: Add Normalization Layer Boundary To Architecture Doc

**Files:**
- Modify: `docs/Live Audio Transcriber Architecture.md`

- [x] **Step 1: Add an implementation note under `4.4 Audio Normalization Layer`**

Add this note after the MVP temporary WAV example and before `4.5 Whisper Inference Layer`:

```markdown
### Implementation Boundary

The app implementation keeps this layer focused on preparing Whisper-ready audio files. It accepts raw `BufferedAudioChunk` values, validates the sample layout, downmixes interleaved input to mono, resamples to 16 kHz, writes signed 16-bit PCM WAV files under a temporary `live-transcriber` directory, and returns normalized chunk metadata with the file URL. It does not invoke Whisper, parse model output, deduplicate transcripts, manage recording state, or update SwiftUI directly.
```

- [x] **Step 2: Validate markdown whitespace**

Run:

```bash
git diff --check -- 'docs/Live Audio Transcriber Architecture.md'
```

Expected: no output and exit code 0.

---

### Task 6: Final Verification

**Files:**
- Verify all files touched in this plan.

- [x] **Step 1: Check formatting whitespace**

Run:

```bash
git diff --check -- falsoai-lens/Pipelines/Hearing 'docs/Live Audio Transcriber Architecture.md' docs/superpowers/plans/2026-05-06-audio-normalization-layer.md
```

Expected: no output and exit code 0.

- [x] **Step 2: Build the app**

Run:

```bash
xcodebuild -project falsoai-lens.xcodeproj -scheme falsoai-lens -configuration Debug build
```

Expected: build succeeds.

- [x] **Step 3: Confirm scope stayed within Audio Normalization Layer**

Run:

```bash
git status --short
```

Expected new or modified files for this layer:

```text
docs/Live Audio Transcriber Architecture.md
docs/superpowers/plans/2026-05-06-audio-normalization-layer.md
falsoai-lens/Pipelines/Hearing/Models/AudioNormalizationConfiguration.swift
falsoai-lens/Pipelines/Hearing/Models/NormalizedAudioChunk.swift
falsoai-lens/Pipelines/Hearing/Services/AudioNormalizer.swift
falsoai-lens/Pipelines/Hearing/Services/WAVWriter.swift
```

Existing unrelated workspace changes may also appear. Do not revert them. If Whisper execution, transcript assembly, or SwiftUI files appear because of this task, stop and remove those changes from this layer.

---

## Notes For Execution

- `normalize(_:)` returns in-memory 16 kHz mono samples for future callers that do not need a file.
- `normalizeToTemporaryWAV(_:)` is the MVP path because the next layer uses `whisper-cli`.
- WAV samples are written as signed 16-bit PCM even though the in-memory normalized samples remain `Float`.
- The manual resampler is intentionally isolated inside `AudioNormalizer.resampleMono`. Replacing it later with `AVAudioConverter` should not require changes to `AudioChunker`, `WAVWriter`, or downstream inference code.
