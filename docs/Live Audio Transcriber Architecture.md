# Realtime MacBook Audio-to-Text Pipeline Architecture

## 1. Purpose

This document describes the architecture for a macOS realtime audio-to-text transcriber and translator using Whisper `base` as the local speech recognition engine.

The application captures live audio from a MacBook, prepares it for Whisper, runs speech-to-text or speech-to-English translation, and displays the resulting text in a SwiftUI interface.

The initial implementation should prioritize simplicity, local execution, privacy, and a clean path toward future upgrades such as system audio capture, speaker diarization, summarization, and RAG-based memory.

---

## 2. Product Goals

### 2.1 Core Goals

1. Capture live audio from the MacBook microphone.
2. Convert audio into Whisper-compatible chunks.
3. Run local Whisper inference using the multilingual `base` model.
4. Display near-realtime transcript output in the app UI.
5. Support two modes:
   - Transcription: speech to text in the original language.
   - Translation: speech to English text.
6. Keep the MVP local-first and privacy-preserving.

### 2.2 Non-Goals for MVP

The first version does not need to support:

1. True word-by-word streaming.
2. Speaker diarization.
3. Perfect timestamp alignment.
4. System audio capture from Zoom, YouTube, Meet, or other apps.
5. Cloud transcription.
6. Long-term semantic memory.
7. Manipulation analysis or classification.

These features can be added after the base audio pipeline is stable.

---

## 3. High-Level Architecture

```text
MacBook microphone
   ↓
Audio Capture Layer
   ↓
Audio Buffer Layer
   ↓
Chunking Layer
   ↓
Audio Normalization Layer
   ↓
Whisper Inference Layer
   ↓
Transcript Assembly Layer
   ↓
SwiftUI Presentation Layer
   ↓
Storage / Export Layer
```

The system is designed as a pipeline. Each stage has a focused responsibility and passes normalized data to the next stage.

---

## 4. Main Components

## 4.1 Audio Capture Layer

### Responsibility

Capture live microphone audio from the MacBook.

### Recommended Tool

```text
AVAudioEngine
```

### Role

`AVAudioEngine` opens the microphone input and provides continuous audio buffers through an input tap.

### Input

Physical microphone audio.

### Output

Raw audio buffers, usually in the Mac's native input format.

Example source:

```text
Built-in MacBook microphone
External USB microphone
Bluetooth headset microphone
```

### Notes

This layer captures microphone audio only. It does not directly capture system audio from other apps.

For system audio later, add `ScreenCaptureKit` or a virtual audio device such as BlackHole.

### Implementation Boundary

The app implementation keeps this layer focused on microphone capture only. It starts and stops `AVAudioEngine`, installs one input tap, checks microphone permission state, and emits copied audio sample buffers to the next layer. It does not chunk, normalize, write WAV files, invoke Whisper, or update SwiftUI directly.

---

## 4.2 Audio Buffer Layer

### Responsibility

Receive small live audio buffers from `AVAudioEngine` and store them temporarily in memory.

### Role

This layer acts as the bridge between continuous live audio and chunk-based Whisper processing.

Whisper does not process every tiny buffer independently. Instead, the app collects buffers until there is enough audio to form a chunk.

### Input

Small audio buffers from `AVAudioEngine`.

### Output

A rolling in-memory buffer of audio samples.

### Design Notes

The buffer should support:

1. Appending new audio samples.
2. Extracting a fixed-duration chunk.
3. Keeping overlap audio for the next chunk.
4. Clearing itself when recording stops.

### Implementation Boundary

The app implementation keeps this layer focused on in-memory sample storage. It accepts copied `CapturedAudioBuffer` values, validates that the input format stays stable, tracks available duration, extracts raw sample windows when enough audio is available, retains overlap samples for the next extraction, and clears itself when recording stops. It does not resample, convert to mono, write WAV files, invoke Whisper, deduplicate transcript text, or update SwiftUI directly.

---

## 4.3 Chunking Layer

### Responsibility

Divide live audio into fixed-size windows that Whisper can process.

### Recommended MVP Chunk Size

```text
5 seconds
```

### Recommended Overlap

```text
1 second
```

### Example

```text
Chunk 1: 0s-5s
Chunk 2: 4s-9s
Chunk 3: 8s-13s
Chunk 4: 12s-17s
```

### Why Chunking Is Needed

Whisper is not a true low-latency streaming engine. It works best when given a short audio segment. The app should therefore approximate realtime behavior by repeatedly processing short chunks.

This creates a near-realtime experience:

```text
Capture → chunk → transcribe → append text → repeat
```

### Tradeoff

| Chunk Size | Latency | Accuracy | CPU Load |
|---|---:|---:|---:|
| 2-3 seconds | Lower | Worse context | Higher overhead |
| 5 seconds | Balanced | Good enough | Moderate |
| 10 seconds | Higher | Better context | Lower overhead |

For the MVP, use 5 seconds.

### Implementation Boundary

The app implementation keeps this layer focused on chunking policy and buffer coordination. It uses the MVP 5-second chunk duration with 1 second of overlap, appends incoming `CapturedAudioBuffer` values to `AudioBufferStore`, drains every ready `BufferedAudioChunk`, and clears chunking state when recording stops. It does not resample audio, convert channels, write WAV files, invoke Whisper, assemble transcripts, or update SwiftUI directly.

---

## 4.4 Audio Normalization Layer

### Responsibility

Convert captured audio into a format Whisper can reliably process.

### Target Format

```text
16 kHz
Mono
PCM WAV
```

### Role

Mac microphone input may arrive as 44.1 kHz, 48 kHz, stereo, or another format. Whisper works best with normalized speech audio. This layer converts each chunk before passing it to Whisper.

### Input

Raw chunk from the rolling audio buffer.

### Output

Temporary `.wav` file or in-memory PCM data.

### MVP Recommendation

For simplicity, write each chunk to a temporary WAV file.

Example:

```text
/tmp/live-transcriber/chunk-0001.wav
/tmp/live-transcriber/chunk-0002.wav
/tmp/live-transcriber/chunk-0003.wav
```

This makes integration with `whisper.cpp` easier because the CLI can process files directly.

### Implementation Boundary

The app implementation keeps this layer focused on preparing Whisper-ready audio files. It accepts raw `BufferedAudioChunk` values, validates the sample layout, downmixes interleaved input to mono, resamples to 16 kHz, writes signed 16-bit PCM WAV files under a temporary `live-transcriber` directory, and returns normalized chunk metadata with the file URL. It does not invoke Whisper, parse model output, deduplicate transcripts, manage recording state, or update SwiftUI directly.

---

## 4.5 Whisper Inference Layer

### Responsibility

Convert normalized audio chunks into text.

### Engine

```text
whisper.cpp
```

### Model

```text
ggml-base.bin
```

Use the multilingual `base` model, not `base.en`, because the application needs multilingual transcription and translation support.

### Modes

#### Mode 1: Transcription

Preserve the original spoken language.

```text
Spanish audio → Spanish text
English audio → English text
French audio → French text
```

Example command:

```bash
whisper-cli \
  -m models/ggml-base.bin \
  -f chunk.wav
```

#### Mode 2: Translation

Translate speech into English text.

```text
Spanish audio → English text
French audio → English text
Japanese audio → English text
```

Example command:

```bash
whisper-cli \
  -m models/ggml-base.bin \
  -f chunk.wav \
  -tr
```

### MVP Integration Strategy

Use `Process` from Swift to call the `whisper.cpp` command-line executable.

This avoids early complexity from linking C/C++ code directly into the Swift app.

### Future Integration Strategy

After the MVP works, replace CLI invocation with a native library wrapper around `whisper.cpp`.

This can improve:

1. Latency.
2. Memory reuse.
3. Error handling.
4. Streaming behavior.
5. Packaging quality.

---

## 4.6 Transcript Assembly Layer

### Responsibility

Turn per-chunk Whisper outputs into a readable continuous transcript.

### Input

Chunk-level text output from Whisper.

Example:

```text
Chunk 1: "Today we're going to talk about..."
Chunk 2: "talk about the architecture of this system..."
Chunk 3: "the architecture of this system and how audio moves..."
```

### Output

A single live transcript.

Example:

```text
Today we're going to talk about the architecture of this system and how audio moves through the pipeline.
```

### Main Problem

Overlapping chunks can produce repeated words.

Example:

```text
Chunk 1: "we need to process the audio"
Chunk 2: "the audio before sending it to Whisper"
```

Naive append result:

```text
we need to process the audio the audio before sending it to Whisper
```

### MVP Deduplication Strategy

Use simple suffix/prefix overlap removal.

The layer should compare the end of the current transcript with the beginning of the new chunk and avoid appending repeated words.

Basic behavior:

```text
Existing transcript: "we need to process the audio"
New chunk: "the audio before sending it to Whisper"
Final transcript: "we need to process the audio before sending it to Whisper"
```

### Future Deduplication Strategy

Later versions can use:

1. Token-level similarity.
2. Timestamp alignment.
3. Whisper segment timestamps.
4. Semantic merge logic.
5. Confidence-aware cleanup.

---

## 4.7 SwiftUI Presentation Layer

### Responsibility

Render the live transcript and expose recording controls.

### Main UI Elements

1. Start button.
2. Stop button.
3. Recording status indicator.
4. Mode selector:
   - Transcribe original language.
   - Translate to English.
5. Live transcript area.
6. Clear transcript button.
7. Copy transcript button.
8. Export transcript button.

### State Model

The UI should observe an app-level transcription controller.

Example state:

```swift
struct TranscriberState {
    var isRecording: Bool
    var selectedMode: TranscriptionMode
    var transcript: String
    var currentChunkStatus: ChunkStatus
    var errorMessage: String?
}
```

### Recommended Pattern

Use a single `ObservableObject` or `@Observable` app controller for MVP simplicity.

Later, split responsibilities into smaller services.

---

## 4.8 Storage and Export Layer

### Responsibility

Persist transcript output after or during recording.

### MVP Features

1. Copy transcript to clipboard.
2. Export transcript as `.txt`.
3. Clear transcript.

### Future Features

1. Save session history.
2. Export Markdown.
3. Export JSON with timestamps.
4. Export subtitles as `.srt` or `.vtt`.
5. Store transcript chunks in SQLite.
6. Send transcript to a RAG pipeline.

---

# 5. Data Flow

## 5.1 Live Capture Flow

```text
1. User clicks Start.
2. App requests microphone permission if needed.
3. AVAudioEngine starts capturing microphone input.
4. Audio buffers are appended to the rolling buffer.
5. The chunking layer extracts a 5-second chunk.
6. Audio normalization converts the chunk to 16 kHz mono WAV.
7. Whisper `base` processes the WAV file.
8. The transcript assembly layer merges the new text.
9. SwiftUI updates the transcript view.
10. The pipeline repeats until the user clicks Stop.
```

## 5.2 Stop Flow

```text
1. User clicks Stop.
2. AVAudioEngine stops.
3. Input tap is removed.
4. Remaining audio buffer is flushed if large enough.
5. Final chunk is processed.
6. Temporary audio files are deleted.
7. UI changes status to Stopped.
```

---

# 6. Threading and Concurrency

## 6.1 Main Thread

The main thread should only handle UI updates and light state changes.

It should not run Whisper inference.

### Main-thread responsibilities

1. Start/stop button actions.
2. Transcript rendering.
3. Error display.
4. Mode selection.

## 6.2 Audio Thread

`AVAudioEngine` audio callbacks should stay lightweight.

Do not run blocking operations in the audio callback.

The audio tap should only:

1. Receive the buffer.
2. Copy or append the buffer into a thread-safe queue.
3. Return quickly.

## 6.3 Background Processing Queue

Whisper processing should run on a background task or queue.

Responsibilities:

1. Extract chunks.
2. Convert audio.
3. Run Whisper.
4. Parse output.
5. Send result back to the main actor.

## 6.4 Recommended Concurrency Model

Use:

```text
MainActor for UI state
Background Task for chunk processing
Thread-safe buffer actor for audio samples
```

Example conceptual structure:

```text
TranscriberController @MainActor
   ↓
AudioCaptureService
   ↓
AudioBuffer actor
   ↓
ChunkProcessor actor
   ↓
WhisperService
```

---

# 7. Proposed Swift Module Boundaries

## 7.1 App Layer

```text
LiveTranscriberApp
ContentView
TranscriberViewModel
```

Responsible for UI and user interaction.

## 7.2 Application Layer

```text
TranscriptionController
TranscriptionSession
TranscriptAssembler
```

Responsible for orchestration.

## 7.3 Audio Layer

```text
AudioCaptureService
AudioBufferStore
AudioChunker
AudioNormalizer
WAVWriter
```

Responsible for capture and audio preparation.

## 7.4 Inference Layer

```text
TranscriptionEngine protocol
WhisperCppEngine
AppleSpeechEngine optional later
```

Responsible for converting audio into text.

## 7.5 Infrastructure Layer

```text
FileSystemTempStore
ProcessRunner
ModelManager
ExportService
```

Responsible for local file management, CLI execution, model location, and exports.

---

# 8. Key Interfaces

## 8.1 Transcription Engine Protocol

```swift
protocol TranscriptionEngine {
    func transcribe(audioFile: URL, mode: TranscriptionMode) async throws -> TranscriptionResult
}
```

## 8.2 Transcription Mode

```swift
enum TranscriptionMode {
    case transcribeOriginalLanguage
    case translateToEnglish
}
```

## 8.3 Transcription Result

```swift
struct TranscriptionResult {
    let text: String
    let segments: [TranscriptSegment]
    let language: String?
    let duration: TimeInterval?
}
```

## 8.4 Transcript Segment

```swift
struct TranscriptSegment {
    let startTime: TimeInterval?
    let endTime: TimeInterval?
    let text: String
}
```

## 8.5 Audio Chunk

```swift
struct AudioChunk {
    let id: UUID
    let sequenceNumber: Int
    let startTime: TimeInterval
    let duration: TimeInterval
    let fileURL: URL
}
```

---

# 9. Whisper Execution Strategy

## 9.1 CLI-Based MVP

The MVP should call `whisper-cli` using Swift's `Process` API.

### Transcription

```bash
whisper-cli \
  -m models/ggml-base.bin \
  -f /tmp/live-transcriber/chunk-0001.wav
```

### Translation

```bash
whisper-cli \
  -m models/ggml-base.bin \
  -f /tmp/live-transcriber/chunk-0001.wav \
  -tr
```

## 9.2 Output Format

For MVP simplicity, parse plain text output.

For better structure, configure Whisper to output JSON or segment files if available in the local build.

Preferred future output:

```json
{
  "text": "...",
  "segments": [
    {
      "start": 0.0,
      "end": 4.8,
      "text": "..."
    }
  ]
}
```

## 9.3 Process Lifecycle

Each chunk can initially launch a new `whisper-cli` process.

This is simple but not optimal.

### MVP

```text
One chunk = one process invocation
```

### Optimized Version

```text
Long-lived Whisper context in native library wrapper
```

The optimized version should avoid reloading the model for every chunk.

---

# 10. Performance Expectations

## 10.1 Model Choice

The app uses Whisper `base`.

Approximate profile:

```text
Model: base multilingual
Disk: roughly 57-142 MB depending on quantization
Practical RAM: usually under 1 GB
Accuracy: usable minimum
Speed: good for MVP near-realtime use
```

## 10.2 Latency Sources

Main latency comes from:

1. Waiting for enough audio to form a chunk.
2. Writing the chunk to disk.
3. Running Whisper inference.
4. Parsing output.
5. Deduplicating text.

## 10.3 Latency Formula

Approximate perceived latency:

```text
latency = chunk_duration + inference_time + processing_overhead
```

For a 5-second chunk:

```text
latency ≈ 5 seconds + Whisper processing time
```

If this feels too slow, test 3-second chunks.

---

# 11. Error Handling

## 11.1 Permission Errors

Possible causes:

1. Microphone permission denied.
2. App sandbox missing microphone entitlement.
3. macOS privacy settings blocked access.

UI behavior:

```text
Show clear error message and provide instruction to enable microphone access in System Settings.
```

## 11.2 Whisper Model Errors

Possible causes:

1. Model file missing.
2. Wrong model path.
3. Model incompatible with local `whisper.cpp` build.
4. Insufficient permissions to read model file.

UI behavior:

```text
Show model error and allow the user to select or reinstall the model.
```

## 11.3 Whisper Execution Errors

Possible causes:

1. `whisper-cli` missing.
2. Process failed.
3. Chunk file invalid.
4. Audio file too short.
5. Unsupported format.

UI behavior:

```text
Skip failed chunk, log the error, continue recording if possible.
```

## 11.4 Audio Conversion Errors

Possible causes:

1. Unsupported input sample rate.
2. Failed WAV writing.
3. Empty buffer.
4. File-system write failure.

UI behavior:

```text
Show transient error or skip chunk depending on severity.
```

---

# 12. Temporary File Strategy

## 12.1 Directory

Use an app-specific temporary directory.

Example:

```text
~/Library/Caches/LiveTranscriber/tmp
```

or

```text
/tmp/live-transcriber
```

## 12.2 File Naming

```text
chunk-000001.wav
chunk-000002.wav
chunk-000003.wav
```

## 12.3 Cleanup

Delete chunk files after successful processing unless debug mode is enabled.

Debug mode can preserve files for inspection.

---

# 13. Security and Privacy

## 13.1 Local-First Design

The MVP should keep all audio local.

Audio should not be uploaded to a server.

## 13.2 Sensitive Data

Live transcription can capture sensitive information. The app should avoid storing audio by default.

Recommended defaults:

1. Do not keep raw audio after processing.
2. Do not upload audio.
3. Do not persist transcripts unless the user explicitly saves them.
4. Clearly show when recording is active.

## 13.3 Permissions

The app requires microphone permission.

Future system audio capture will require additional screen/audio capture permissions.

---

# 14. MVP Build Plan

## Phase 1: Microphone Capture

Deliverables:

1. Start/Stop recording.
2. Capture live microphone audio with `AVAudioEngine`.
3. Display recording status.

## Phase 2: Chunk Creation

Deliverables:

1. Rolling audio buffer.
2. 5-second chunk extraction.
3. 1-second overlap.
4. WAV file output.

## Phase 3: Whisper Integration

Deliverables:

1. Install or bundle `whisper.cpp`.
2. Load `ggml-base.bin`.
3. Run transcription mode.
4. Run translation mode with `-tr`.
5. Parse output text.

## Phase 4: Transcript UI

Deliverables:

1. Live transcript area.
2. Append chunk output.
3. Basic deduplication.
4. Clear button.
5. Copy button.

## Phase 5: Export

Deliverables:

1. Export `.txt`.
2. Save current transcript manually.
3. Optional timestamp export.

---

# 15. Future Extensions

## 15.1 System Audio Capture

Add support for capturing audio directly from apps using:

```text
ScreenCaptureKit
```

or a virtual audio device:

```text
BlackHole
```

New pipeline:

```text
System audio / app audio
   ↓
ScreenCaptureKit or virtual audio input
   ↓
Same chunking and Whisper pipeline
```

## 15.2 Voice Activity Detection

Add VAD to avoid running Whisper when there is no speech.

Benefits:

1. Lower CPU usage.
2. Lower battery usage.
3. Cleaner transcript.
4. Fewer empty chunks.

Possible strategies:

1. Energy threshold detection.
2. WebRTC VAD.
3. Apple SpeechDetector.
4. Lightweight ML speech detector.

## 15.3 Speaker Diarization

Add speaker labeling later.

Example output:

```text
Speaker 1: I think we should ship the MVP first.
Speaker 2: Agreed, but we need better chunk cleanup.
```

This likely requires a separate diarization model or external service.

## 15.4 Transcript Cleanup

Add an LLM cleanup pass after transcription.

Possible modes:

1. Fix punctuation.
2. Remove duplicate overlap text.
3. Format as meeting notes.
4. Extract action items.
5. Summarize.
6. Detect manipulation signals.

## 15.5 RAG Memory

Store processed transcripts in a searchable memory layer.

Potential categories:

1. Meetings.
2. Videos.
3. Video calls.
4. News.
5. Social networking.
6. Personal notes.

Pipeline:

```text
Transcript
   ↓
Chunk by semantic sections
   ↓
Generate embeddings
   ↓
Store in vector database
   ↓
Retrieve relevant context later
```

---

# 16. Recommended Initial Architecture

For the first build, use this exact architecture:

```text
SwiftUI App
   ↓
TranscriberViewModel
   ↓
AudioCaptureService using AVAudioEngine
   ↓
RollingAudioBuffer
   ↓
AudioChunker, 5-second chunks with 1-second overlap
   ↓
WAVWriter, 16 kHz mono PCM
   ↓
WhisperCppEngine using whisper-cli and ggml-base.bin
   ↓
TranscriptAssembler with basic deduplication
   ↓
SwiftUI transcript display
```

This design is simple enough to build quickly but modular enough to evolve into a more serious local audio intelligence pipeline.

---

# 17. Final Recommendation

Start with the CLI-based Whisper integration and the `base` multilingual model.

Do not optimize prematurely.

The first milestone should be:

```text
Speak into the MacBook microphone → see translated or transcribed text appear in the app within a few seconds.
```

Once that works, improve latency, deduplication, and system audio capture.
