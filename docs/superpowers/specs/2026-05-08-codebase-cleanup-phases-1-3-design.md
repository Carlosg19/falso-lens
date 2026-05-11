# Codebase Cleanup: Phases 1–3 (2026-05-08)

## Goal

Reduce drift, eliminate dead code, and clarify naming in `falsoai-lens` without changing runtime behavior. Three phases executed in order; each phase ends with a Debug build.

## Out of scope

- ContentView decomposition (Phase 4 — deferred)
- Large-file decomposition for `LiveAudioTranscriptionPipeline`, `WhisperCppEngine`, `RMSVoiceActivityDetector`, `TranscriptDuplicateAnalyzer` (Phase 5 — deferred)
- `Models/` directory consolidation
- Touching historical artifacts under `docs/superpowers/plans/` and `docs/superpowers/specs/` (these describe past work as it was; not rewritten)

---

## Phase 1 — Safe deletions

All deletions cross-checked against the working tree. Listed targets have zero live references outside the file being touched.

### 1.1 Finish in-progress edit

`falsoai-lens/Pipelines/Hearing/Inference/TranscriptSimilarityHelpers.swift` already has an uncommitted diff removing `rmsDBFS(for:)` and `peakAmplitude(for:)`.

Verification: only callers live in `Pipelines/Hearing/Inference/RMSVoiceActivityDetector.swift` at lines 186 and 315, and they call a **private static** `rmsDBFS(_:)` defined inside that file with an `ArraySlice<Float>` signature. The removed helpers operate on `[Float]` and are not invoked anywhere.

Action: no further edits; the existing working-tree diff is correct.

### 1.2 Delete `Services/AnalyzerService.swift`

Posts to a remote `http://127.0.0.1:8787/analyze` endpoint that was never wired. The live analyzer is `LocalHeuristicAnalyzer` (used by `DemoScanPipeline`). Grep confirms zero references outside the file.

Action: `rm falsoai-lens/Services/AnalyzerService.swift`.

### 1.3 Remove SwiftData / `Item`

`Item.swift` is a template stub; `Schema([Item.self])` and `ModelContainer` in `falsoai_lensApp.swift` are initialized but never queried. No view uses `@Query`, `@Environment(\.modelContext)`, or `.modelContext`. GRDB via `ScanStorage` is the live persistence.

Actions:

- `rm falsoai-lens/Item.swift`
- In `falsoai-lens/falsoai_lensApp.swift`: remove `import SwiftData`, the `sharedModelContainer` property, and the `.modelContainer(sharedModelContainer)` modifier.

### 1.4 Drop unused imports in `ContentView.swift`

- `import SwiftData` — only used by the `.modelContainer` preview/runtime modifier removed in 1.3.
- `import UniformTypeIdentifiers` — confirmed no `UTType` references in the file; `NSOpenPanel` uses string extensions, not UTType.

Keep `import CoreAudio` — `AudioDeviceID` is referenced for the device picker `.tag()`.

### 1.5 Verification

```bash
xcodebuild -project falsoai-lens.xcodeproj -scheme falsoai-lens -configuration Debug build
```

Expect `BUILD SUCCEEDED`.

---

## Phase 2 — Doc drift fixes

Update `CLAUDE.md` and `AGENTS.md` (they mirror each other) to match the implemented architecture.

### Changes

| Area | Current text | Replacement |
|------|-------------|-------------|
| Project description | "Planned/architected next pipeline: Live microphone transcription…" | Move audio bullets into "Current implemented MVP"; add: live microphone + computer-audio capture via two independent `LiveAudioTranscriptionPipeline` instances, cross-source `TranscriptDuplicateAnalyzer`. |
| Whisper model | "Use the multilingual Whisper `base` model, not `base.en`." | "Bundled model is `ggml-small.bin` (multilingual)." |
| Persistence | "SwiftData is configured in `falsoai_lensApp.swift`." | Drop. After Phase 1, GRDB is the only persistence. |
| Architecture diagram | Single `DemoScanPipeline` flow | Add a parallel Hearing flow: `LiveAudioCaptureProvider` → `AudioBufferStore` → `AudioChunker` → `AudioNormalizer` → `WhisperCppEngine` → `TranscriptDuplicateAnalyzer`. |
| Key files | `DemoScanPipeline.swift`, `HearingDemoPipeline.swift` (current names) | Updated names from Phase 3 (`ScanPipeline.swift`, `FileTranscriptionPipeline.swift`). |
| `docs/Live Audio Transcriber Architecture.md` reference | "Use it as the source of truth for the planned audio MVP." | Note it as historical reference; current architecture is the code itself. |

Both files get the same edits, kept in sync.

---

## Phase 3 — Renames

Rename two types whose `Demo` prefix is misleading (both are fully functional, not demos).

### 3.1 `DemoScanPipeline` → `ScanPipeline`

| File | Change |
|------|--------|
| `falsoai-lens/Pipelines/Vision/Services/DemoScanPipeline.swift` → `ScanPipeline.swift` | Rename file. Rename `final class DemoScanPipeline`. Update OSLog category. |
| `falsoai-lens/ContentView.swift` | `@StateObject private var pipeline = DemoScanPipeline()` → `ScanPipeline()` |
| `CLAUDE.md`, `AGENTS.md` | Update key-files list and architecture diagram. |

### 3.2 `HearingDemoPipeline` → `FileTranscriptionPipeline`

| File | Change |
|------|--------|
| `falsoai-lens/Pipelines/Hearing/Services/HearingDemoPipeline.swift` → `FileTranscriptionPipeline.swift` | Rename file. Rename class. Update OSLog category and logger error strings. |
| `falsoai-lens/ContentView.swift` | `@StateObject private var hearing = HearingDemoPipeline()` → `FileTranscriptionPipeline()` |
| `CLAUDE.md`, `AGENTS.md` | Update key-files list. |

### Not renamed

- `LiveAudioTranscriptionPipeline` — already well-named.
- The "Run Demo Scan" button label in `ContentView.swift` — user-facing copy, not a code name.
- Historical files under `docs/superpowers/plans/` and `docs/superpowers/specs/` — these are dated artifacts; rewriting them would erase context.

### 3.3 Verification

```bash
xcodebuild -project falsoai-lens.xcodeproj -scheme falsoai-lens -configuration Debug build
```

Expect `BUILD SUCCEEDED`. Then a final grep:

```bash
grep -rn "DemoScanPipeline\|HearingDemoPipeline" falsoai-lens/ CLAUDE.md AGENTS.md
```

Expect zero matches in those paths.

---

## Phase ordering rationale

1 → 2 → 3, because:

- Phase 1 removes files referenced in CLAUDE.md (SwiftData mention). Doc fix in Phase 2 must reflect the deletion.
- Phase 2 lists current file names. Phase 3 then renames; the doc update in Phase 2 can name the new files directly, avoiding a second pass.

To avoid two doc edits, Phase 2 writes the post-rename file names. Phase 3 then changes only Swift code and call sites. (Slightly out-of-order on the surface, but minimizes churn.)
