# VAD Pre-Pass (Silence Trimming) — Design Spec

**Date:** 2026-05-06
**Status:** Approved (design only; implementation plan to follow)
**Scope:** Adds a Voice Activity Detection pre-pass to the Whisper Inference Layer to eliminate hallucination loops caused by silent audio stretches.
**Builds on:** [2026-05-06-whisper-inference-layer-design.md](2026-05-06-whisper-inference-layer-design.md), [Live Audio Transcriber Architecture §15.2](../../../docs/Live%20Audio%20Transcriber%20Architecture.md).

## 1. Purpose

The Whisper Inference Layer ([previous spec](2026-05-06-whisper-inference-layer-design.md)) ships `whisper.cpp` with the multilingual `small` model. On real-world recordings — particularly recordings with quiet/silent stretches at the end — `whisper.cpp` enters a hallucination loop, repeating filler phrases like `(speaking in Spanish)` for the duration of the silent tail. This was reproduced live during the Whisper Inference Layer verification: a Spanish-language video produced 38 consecutive `(speaking in Spanish)` lines after the actual speech ended.

This spec adds a Voice Activity Detection (VAD) pre-pass to the engine. Before whisper.cpp sees the audio, an `RMSVoiceActivityDetector` trims leading and trailing silence from the WAV. Whisper only sees the voiced middle. If the entire file is silence, whisper is not invoked at all and the engine returns an empty `TranscriptionResult`.

This is the smallest correct intervention. It does **not** address inter-region hallucinations (a long silent gap between two voiced segments would still pass to whisper); that's a follow-up plan ([§10 Out of Scope](#10-out-of-scope)).

## 2. Decisions Locked During Brainstorming

| # | Decision | Rationale |
|---|---|---|
| 1 | **Trim only**, not gate-only or split-on-voiced. | Smallest fix that addresses the actual failure mode (silent-tail hallucination). API shape leaves clean room for gate/split as later additions. |
| 2 | **RMS energy threshold**, not Silero/SoundAnalysis ML classifiers. | Silent stretches are by definition low-energy; RMS detects this exactly. Zero dependencies, ~30 LOC of pure Swift, deterministic, no Metal/CoreML needed. ML classifiers become valuable only when we want speech-vs-noise discrimination — out of scope for trim. |
| 3 | **Standalone `VoiceActivityDetector` protocol + `RMSVoiceActivityDetector` impl**, composed by `WhisperCppEngine` via optional init parameter, defaulting to enabled. | One seam, fully testable in isolation, mirrors how `AudioNormalizer` composes `WAVWriter`. Future implementations (Silero, SoundAnalysis) are drop-in replacements. |

## 3. File Layout

```
falsoai-lens/
├── Pipelines/Hearing/
│   ├── Inference/
│   │   ├── VoiceActivityDetector.swift           ← NEW protocol + error type
│   │   ├── RMSVoiceActivityDetector.swift        ← NEW concrete impl (actor)
│   │   ├── TranscriptionEngine.swift             (unchanged)
│   │   └── WhisperCppEngine.swift                ← edit: compose VAD
│   └── (existing Models/, Services/, Resources/ unchanged)
└── Dependencies/Hearing/
    └── HearingDependencies.swift                 ← edit: VAD defaults
```

No new bundled binaries, no new external dependencies, no Xcode project changes. Pure Swift addition.

## 4. Components and Public Contracts

### 4.1 `VoiceActivityDetector` protocol

```swift
protocol VoiceActivityDetector: Sendable {
    /// Trim leading and trailing silence from a 16 kHz mono PCM WAV file.
    /// - Returns: a new WAV URL containing only the voiced portion (with
    ///   configured padding), or `nil` if no voice was detected anywhere
    ///   in the file (or only briefly enough to be classified as transient).
    /// - Throws: `VoiceActivityError` on read/write/format failures.
    func trimSilence(in audioFile: URL) async throws -> URL?
}
```

The protocol is `async` because future implementations (Silero, SoundAnalysis) may load models or do background work. The RMS implementation is synchronous internally but conforms via `async`.

### 4.2 `VoiceActivityError`

```swift
enum VoiceActivityError: LocalizedError, Equatable {
    case audioFileNotFound(URL)
    case unsupportedAudioFormat(sampleRate: Double, channelCount: UInt32)
    case decodeFailed(String)
    case encodeFailed(String)

    var errorDescription: String? { /* … */ }
    var recoverySuggestion: String? { /* … */ }
}
```

`unsupportedAudioFormat` covers the case where the input WAV is not 16 kHz mono PCM — VAD assumes the upstream `AudioNormalizer` (or `HearingDemoPipeline`'s caller) has already normalized format. Today the engine itself does not check format; VAD adds this as a defensive contract.

### 4.3 `RMSVoiceActivityDetectorConfiguration`

```swift
struct RMSVoiceActivityDetectorConfiguration: Sendable, Equatable {
    var windowDurationSeconds: TimeInterval         // default 0.030  (30 ms)
    var thresholdDBFS: Double                       // default -40.0  (-40 dBFS)
    var paddingSeconds: TimeInterval                // default 0.200  (200 ms)
    var minimumVoicedDurationSeconds: TimeInterval  // default 0.100  (100 ms)

    static let `default` = RMSVoiceActivityDetectorConfiguration(
        windowDurationSeconds: 0.030,
        thresholdDBFS: -40.0,
        paddingSeconds: 0.200,
        minimumVoicedDurationSeconds: 0.100
    )
}
```

Default rationale:

- **30 ms windows** — standard VAD frame size; captures syllable-level dynamics without per-frame jitter.
- **−40 dBFS threshold** — quieter than whispered speech (~−30 dBFS), louder than typical room tone (~−55 dBFS). Empirically right for `say`-generated audio and clean voiceover.
- **200 ms padding** — covers attack of the first phoneme and decay of the last; without it whisper's tokenizer sees a clipped onset and may drop the first word.
- **100 ms minimum voiced** — anything shorter is almost certainly a click or transient, not actual speech; treat the whole file as silence.

### 4.4 `RMSVoiceActivityDetector`

```swift
actor RMSVoiceActivityDetector: VoiceActivityDetector {
    init(configuration: RMSVoiceActivityDetectorConfiguration = .default)
    func trimSilence(in audioFile: URL) async throws -> URL?
}
```

`actor` because each call holds state during the trim (sample buffer, decoded frames). Concurrent `trimSilence` calls serialize within the actor, which is correct given the underlying `AVAudioFile` read/write isn't parallelizable on a single instance.

### 4.5 `WhisperCppEngine` updated init

```swift
init(
    executableURL: URL? = nil,
    modelURL: URL? = nil,
    voiceActivityDetector: VoiceActivityDetector? = RMSVoiceActivityDetector(),
    deletesJSONSidecarOnSuccess: Bool = true
) throws
```

New optional `voiceActivityDetector` parameter, **defaults to enabled** with the `RMSVoiceActivityDetector` `.default` configuration. Pass `nil` to disable VAD entirely (useful for tests, debugging, or future engine variants where VAD lives elsewhere in the pipeline).

## 5. Algorithm

`RMSVoiceActivityDetector.trimSilence(in:)`:

1. Verify the file exists; throw `audioFileNotFound` otherwise.
2. Open via `AVAudioFile(forReading:)`. Read its `processingFormat` and `length`.
3. **Format gate.** If `format.sampleRate != 16_000` or `format.channelCount != 1`, throw `unsupportedAudioFormat(sampleRate:channelCount:)`. (`AudioNormalizer` produces exactly this format; a user-picked file in `HearingDemoPipeline` is also expected to match per the demo UI's "Pick a 16 kHz mono WAV" prompt. We could resample here in a later iteration; out of scope for this spec.)
4. Decode into a contiguous `[Float]` of mono samples. (Single `AVAudioFile.read(into:)` into an `AVAudioPCMBuffer` sized to file length.)
5. Compute window count: `windowSamples = Int(windowDurationSeconds * 16000)` (= 480), `windowCount = sampleCount / windowSamples`.
6. For each window `i` in `0..<windowCount`:
   - Compute `rms = sqrt( mean( samples[i·480 ..< (i+1)·480]² ) )`.
   - Compute `dBFS = 20 · log10(max(rms, 1e-10))` (clamp to avoid −∞).
   - Mark window as **voiced** iff `dBFS >= thresholdDBFS`.
7. Find `firstVoicedWindow` (smallest index with voiced=true) and `lastVoicedWindow` (largest index with voiced=true).
8. If no voiced window exists, **return `nil`** — engine treats this as the empty-result case.
9. Compute voiced duration: `(lastVoicedWindow - firstVoicedWindow + 1) · windowDurationSeconds`. If less than `minimumVoicedDurationSeconds`, **return `nil`**.
10. Compute the padded sample range:
    - `startSample = max(0, firstVoicedWindow · windowSamples − paddingSamples)`
    - `endSample = min(sampleCount, (lastVoicedWindow + 1) · windowSamples + paddingSamples)`
    - where `paddingSamples = Int(paddingSeconds * 16000)` (= 3200).
11. Slice samples to `[startSample ..< endSample]`.
12. Write the slice to `URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true).appendingPathComponent("vad-trimmed-<UUID>.wav")` via `AVAudioFile(forWriting:settings:)` using the same processing format. (Note: `NSTemporaryDirectory()` returns a `String`, not a `URL`; the explicit `URL(fileURLWithPath:)` wrap is required.)
13. Return the new URL.

Numerical edge cases:

- **All-silence file** → step 8 returns nil. ✓
- **All-voiced file** → step 7 returns `(0, windowCount-1)`, padding clamps both sides, written file is essentially the input (acceptable; tiny extra cost).
- **Single voiced burst at end** → padding extends backwards, possibly to start; clamp at 0. ✓
- **Sub-window file (length < 480 samples)** → `windowCount == 0`, no voiced windows, return nil. (Audio shorter than 30 ms is almost certainly noise.)

## 6. `WhisperCppEngine.transcribe(...)` integration

The current engine flow ([previous spec §5.2](2026-05-06-whisper-inference-layer-design.md)) becomes:

```
1.  validateAudioFile(audioFile)
2.  if voiceActivityDetector != nil:
        trimmedURL = try await voiceActivityDetector.trimSilence(in: audioFile)
        if trimmedURL == nil:
            logger.info("VAD found no voice; skipping whisper invocation")
            return TranscriptionResult(text: "", segments: [], language: nil, duration: 0)
        workingURL = trimmedURL
    else:
        workingURL = audioFile
3.  defer { if trimmedURL != nil { try? FileManager.default.removeItem(at: trimmedURL) } }
4.  outputPrefix = NSTemporaryDirectory() + "whisper-output-<UUID>"
5.  runWhisper(audioFile: workingURL, mode: mode, outputPrefix: outputPrefix)
6.  if exitCode != 0: throw .processFailed(...)
7.  read JSON sidecar, decode TranscriptionResult, return
```

Logging additions (category `WhisperEngine`):

- Before VAD: `vad.input audioFile=<url>`
- After VAD success: `vad.trimmed inputDurationSeconds=<X>, outputDurationSeconds=<Y>, voicedRatio=<Y/X>`
- After VAD nil: `vad.noVoice inputDurationSeconds=<X>` and engine returns empty result without calling whisper.

Privacy classification of audio file paths in logs follows the existing `privacy: .private` convention.

## 7. UI behavior in `HearingDemoPipeline` / `ContentView`

When the engine returns `TranscriptionResult(text: "", segments: [], …)`:

- `latestResult` is set to the empty result (so the UI updates and the "Selected: …" hint can clear).
- `errorMessage` is set to: **"No voice detected in the selected file. The file may be silent, or its content fell below the −40 dBFS detection threshold."**
- The transcript pane and segments list don't render (their existing `if let result = …, !result.text.isEmpty` guard handles this).

This is the only ContentView change needed. Mode picker, file picker, and the rest of the demo UI are unchanged.

## 8. Concurrency, logging, error handling

- `RMSVoiceActivityDetector` is an **actor** (one trim per instance at a time, mirrors `AudioNormalizer`).
- `os.Logger` category `VoiceActivity` for all DSP-side logs (window count, voiced ratio, trim boundaries, failures).
- Error message text in `VoiceActivityError` matches the project's existing `LocalizedError` format (description + recovery suggestion).
- `WhisperCppEngine` swallows `VoiceActivityError` and re-throws as `WhisperEngineError.processFailed(exitCode: -1, stderr: "VAD failed: …")` — the orchestrator already handles `WhisperEngineError` cleanly, so this avoids exposing a second error type to the UI.

## 9. Verification Protocol

Mirroring [the previous spec's §9](2026-05-06-whisper-inference-layer-design.md), verification has three layers and the implementation is complete only when **all** pass.

### 9.1 Parser-style fixture smoke check (debug-only, runs at engine init)

A new `RMSVoiceActivityDetector.runVADSmokeCheck()` synthesizes a known waveform in code (rather than bundling a fixture WAV — keeps repo small): a 1-second silent block, a 1-second 440 Hz sine burst at 0 dBFS, a 1-second silent block. Writes it to a temp WAV, runs `trimSilence(in:)` against it, asserts:

- Returned URL is non-nil.
- Decoded output duration is in `[1.0 + padding − 30 ms, 1.0 + 2·padding + 30 ms]` (= roughly 1.4–1.5 s for `paddingSeconds = 0.200`).
- Output starts with the burst, not the leading silence.

`HearingDemoPipeline.init` calls both `WhisperCppEngine.runParserSmokeCheck()` and `RMSVoiceActivityDetector.runVADSmokeCheck()` in `#if DEBUG`. Either failure asserts at launch.

### 9.2 Real-world manual smoke test

Re-run the same Spanish video that previously produced the 38-line `(speaking in Spanish)` hallucination tail. Expected: tail is gone or reduced to ≤ 2 lines.

### 9.3 Negative test (pure-silence file)

Generate a pure-silence WAV. Easiest path on macOS:

```bash
# Use `say` with a punctuation-only string to produce a near-silent AIFF,
# then convert to 16 kHz mono WAV.
say "." -o /tmp/silence.aiff
afconvert -f WAVE -d LEI16@16000 -c 1 /tmp/silence.aiff /tmp/silence.wav
```

(If `say "."` doesn't produce sufficiently silent audio in your locale, generate a silent buffer in Swift via `AVAudioFile` write of zero-valued `Float` samples — the implementation plan can include a small helper.)

Pick `/tmp/silence.wav` in the demo, click Transcribe.

Expected:
- App does not crash.
- Transcript pane is empty.
- Error message reads "No voice detected in the selected file. …"
- Console log shows `vad.noVoice` line; whisper-cli was never invoked (no `whisper-cli launching` log line).

### 9.4 Verification commands

```bash
# 1. Build succeeds.
xcodebuild -project falsoai-lens.xcodeproj -scheme falsoai-lens -configuration Debug build

# 2. After running 9.2, no leaked temp files.
ls "$HOME/Library/Containers/com.falsoai.FalsoaiLens/Data/tmp/"
# Expected: no vad-trimmed-* and no whisper-output-* sidecars.

# 3. Inspect the temp file shape during a transcription (debugging only):
ls "$HOME/Library/Containers/com.falsoai.FalsoaiLens/Data/tmp/vad-trimmed-*"
# Should appear briefly during transcription, vanish after.
```

## 10. Out of Scope

Tracked for follow-up plans, deliberately not in this spec:

- **Q1-B / Gate-only mode.** Skip whisper based on overall voiced ratio (e.g., < 5 %) without trimming. Useful at the orchestrator boundary for live-mic chunks; not needed when we already trim.
- **Q1-C / Split-on-voiced-regions.** Split a recording at long silent gaps (e.g., > 2 s), run whisper on each region separately, concatenate transcripts. Eliminates inter-region hallucinations. Conceptually overlaps with the future "Transcript Assembly Layer" ([Live Audio Transcriber Architecture §4.6](../../../docs/Live%20Audio%20Transcriber%20Architecture.md)).
- **Q2-B / SoundAnalysis-based detector.** `SNClassifier` with the system-trained classifier knows speech-vs-noise. Drop-in `VoiceActivityDetector` replacement when discrimination matters.
- **Q2-C / Silero VAD.** `onnxruntime-swift` + Silero ONNX model. Best-in-class accuracy; needed only for live-mic capture with adversarial noise.
- **Format auto-handling.** Resampling/downmixing arbitrary inputs to 16 kHz mono inside the VAD. Currently we throw `unsupportedAudioFormat`; orchestrators are expected to feed normalized audio.
- **Live mic capture wiring.** The audio capture pipeline (`AudioCaptureService → AudioBufferStore → AudioChunker → AudioNormalizer → WhisperCppEngine`) is still not wired end-to-end. That's its own plan once VAD lands.

## 11. Open Risks

- **Padded boundary still leaks silence.** With 200 ms of padding, whisper might still hit a few hundred ms of low-energy audio at the edges and produce small hallucinations there. Mitigation: this spec's verification uses the user's real-world Spanish video; if hallucinations remain at edges, tighten padding (e.g., 100 ms) or revisit threshold.
- **Threshold doesn't generalize across recordings.** −40 dBFS is right for clean voiceover but might cut speech in very-quiet recordings (whispered ASMR-style audio) or fail to cut HVAC-noise tails (e.g., laptop fan recording). Mitigation in the implementation plan: log the input file's mean dBFS so failures are diagnosable; accept that the trim-only design cannot solve "noisy throughout" — that's what Silero/SoundAnalysis are for, and they're explicit follow-ups.
- **`AVAudioFile`-encoded WAVs may not be byte-identical to whisper-cli's expectations.** AVFoundation's WAV encoder has been stable for years and produces standard PCM WAV; whisper.cpp accepts standard WAV. Verified empirically during the previous spec's verification (the demo's user-picked WAVs are read by whisper.cpp without complaint). If a downstream whisper.cpp version becomes pickier, we'd switch to the existing `WAVWriter` actor (which already produces signed-16-bit PCM WAVs accepted by the prior verification).
- **Smoke check on app launch adds startup latency.** The synthesized waveform + AVAudioFile write takes ~50–100 ms in DEBUG. Acceptable; release builds skip it via `#if DEBUG`.
