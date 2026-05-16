# Analyzer Segment Document Input Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Change the window analyzer boundary so analyzers receive the LLM-ready `ScreenTextWindowSegmentDocument` instead of raw `ScreenTextWindow`.

**Architecture:** Keep `ScreenTextWindow` as the upstream sealed-window aggregation for now because it is still useful for `latestWindow`, failure handling, and converting encounter memory into a stable window interval. Build `ScreenTextWindowSegmentDocument` once in `RealtimeScreenTextPipeline`, log that exact payload, and pass the same document into the analyzer. The analyzer should become a consumer of the LLM contract, not the owner of segment reduction or prompt preparation.

**Tech Stack:** Swift 5.0, SwiftUI/Combine project settings, default MainActor isolation, existing DEBUG smoke checks, `xcodebuild` verification. No Xcode project file or entitlement changes.

---

## Files

- Modify: `falsoai-lens/Pipelines/Vision/Services/ScreenTextWindowAnalyzing.swift`
  - Change protocol input from `ScreenTextWindow` to `ScreenTextWindowSegmentDocument`.
- Modify: `falsoai-lens/Pipelines/Vision/Services/StubScreenTextWindowAnalyzer.swift`
  - Remove segment reducer and prompt preparation dependencies.
  - Build stub summary from `ScreenTextWindowSegmentDocument`.
  - Encode the document only for payload-size reporting.
  - Update DEBUG smoke checks to construct segment documents directly.
- Modify: `falsoai-lens/Pipelines/Vision/Services/RealtimeScreenTextPipeline.swift`
  - Export `ScreenTextWindowSegmentDocument` once after sealing the window.
  - Pass that document to logging and analysis.
  - Keep failure handling tied to `ScreenTextWindow`.
- Modify: `falsoai-lens/Pipelines/Vision/Services/ScreenTextLLMPreparationService.swift`
  - Remove `prepareSegmentDocument(_:)`, `prepareSegmentDocumentJSON(_:)`, and its stored `ScreenTextWindowSegmentDocumentExporter` if no call sites remain.
- Read-only validation: `falsoai-lens/Pipelines/Vision/Models/ScreenTextWindowAnalysis.swift`
  - Confirm no schema change is needed because analysis fields map cleanly from `document.window`.

---

### Task 1: Change Analyzer Contract

**Files:**
- Modify: `falsoai-lens/Pipelines/Vision/Services/ScreenTextWindowAnalyzing.swift`
- Modify: `falsoai-lens/Pipelines/Vision/Services/StubScreenTextWindowAnalyzer.swift`

- [ ] **Step 1: Update the protocol signature**

Change:

```swift
func analyze(_ window: ScreenTextWindow) async throws -> ScreenTextWindowAnalysis
```

to:

```swift
func analyze(_ document: ScreenTextWindowSegmentDocument) async throws -> ScreenTextWindowAnalysis
```

- [ ] **Step 2: Update the stub analyzer stored dependencies**

Replace the current reducer/prompt dependencies with an encoder dependency:

```swift
struct StubScreenTextWindowAnalyzer: ScreenTextWindowAnalyzing {
    let analyzerID = "stub-summary-1"
    private let segmentDocumentExporter: ScreenTextWindowSegmentDocumentExporter

    init(
        segmentDocumentExporter: ScreenTextWindowSegmentDocumentExporter = ScreenTextWindowSegmentDocumentExporter()
    ) {
        self.segmentDocumentExporter = segmentDocumentExporter
    }
}
```

- [ ] **Step 3: Update `analyze` to consume the document**

Use the document metadata to fill `ScreenTextWindowAnalysis`:

```swift
func analyze(_ document: ScreenTextWindowSegmentDocument) async throws -> ScreenTextWindowAnalysis {
    let started = Date()
    let payloadJSON = (try? segmentDocumentExporter.compactJSON(document)) ?? ""
    let summary = makeSummary(document: document, payloadJSON: payloadJSON)
    let elapsed = Date().timeIntervalSince(started)
    let window = document.window

    return ScreenTextWindowAnalysis(
        id: UUID(),
        windowID: window.id,
        sessionID: window.sessionID,
        sequenceNumber: window.sequenceNumber,
        windowStartedAt: window.startedAt,
        windowEndedAt: window.endedAt,
        generatedAt: Date(),
        analyzerID: analyzerID,
        summaryMarkdown: summary,
        encounterCount: window.encounterCount,
        latencySeconds: elapsed,
        errorMessage: nil
    )
}
```

- [ ] **Step 4: Update summary generation**

Change `makeSummary(window:payloadJSON:segments:)` to `makeSummary(document:payloadJSON:)`. Use `document.window` for metadata and `document.segments` for segment previews:

```swift
private func makeSummary(
    document: ScreenTextWindowSegmentDocument,
    payloadJSON: String
) -> String {
    let window = document.window
    let header = """
    ## Stub Window Summary

    - Sequence: \(window.sequenceNumber)
    - Window: \(window.startedAt.formatted()) -> \(window.endedAt.formatted())
    - Duration: \(Int(window.durationSeconds.rounded())) s
    - Unique lines: \(window.encounterCount)
    - Segments: \(document.segments.count)
    """

    let segmentSummary: String
    if document.segments.isEmpty {
        segmentSummary = "_(none)_"
    } else {
        segmentSummary = document.segments
            .map { segment in
                "- d\(segment.displayIndex + 1) role=\(segment.role.rawValue) lines=\(segment.lineCount) sightings=\(segment.totalSightingCount) repeatedUI=\(segment.isRepeatedUI)"
            }
            .joined(separator: "\n")
    }

    let preview: String
    if document.segments.isEmpty {
        preview = "_(none)_"
    } else {
        preview = document.segments
            .sorted { $0.firstSightedAt < $1.firstSightedAt }
            .prefix(10)
            .map { segment in
                "- [role \(segment.role.rawValue), lines \(segment.lineCount)] \(segment.text)"
            }
            .joined(separator: "\n")
    }

    return """
    \(header)

    ### Segments
    \(segmentSummary)

    ### Top segment text (chronological, first 10)
    \(preview)

    ---
    LLM payload size: \(payloadJSON.utf8.count) bytes (segment document; would be sent to a real LLM here)
    """
}
```

- [ ] **Step 5: Run a compile check**

Run:

```bash
xcodebuild -project falsoai-lens.xcodeproj -scheme falsoai-lens -configuration Debug build
```

Expected: it may fail in `RealtimeScreenTextPipeline` because the call site still passes `ScreenTextWindow`. That is an expected intermediate failure for this task.

---

### Task 2: Move Segment Document Construction to the Pipeline Boundary

**Files:**
- Modify: `falsoai-lens/Pipelines/Vision/Services/RealtimeScreenTextPipeline.swift`

- [ ] **Step 1: Export the segment document once after sealing**

In `sealAndFlushWindow(at:)`, after `latestWindow = window`, add:

```swift
let segmentDocument = segmentDocumentExporter.export(window)
```

- [ ] **Step 2: Pass the same document to logging**

Change:

```swift
logDebugSegmentDocument(for: window)
```

to:

```swift
logDebugSegmentDocument(segmentDocument)
```

- [ ] **Step 3: Pass the same document to the analyzer**

Change:

```swift
let analysis = try await analyzer.analyze(window)
```

to:

```swift
let analysis = try await analyzer.analyze(segmentDocument)
```

Keep this line unchanged:

```swift
await self?.handleAnalysisFailed(error: error, window: window)
```

The failure path still needs the raw window metadata to create an error analysis.

- [ ] **Step 4: Change the debug logger signature**

Replace:

```swift
private func logDebugSegmentDocument(for window: ScreenTextWindow) {
    let document = segmentDocumentExporter.export(window)
    let json: String
    do {
        json = try segmentDocumentExporter.compactJSON(document)
    } catch {
        json = "{\"error\":\"failed to encode segment document: \(error.localizedDescription)\"}"
    }
    ...
}
```

with:

```swift
private func logDebugSegmentDocument(_ document: ScreenTextWindowSegmentDocument) {
    let json: String
    do {
        json = try segmentDocumentExporter.compactJSON(document)
    } catch {
        json = "{\"error\":\"failed to encode segment document: \(error.localizedDescription)\"}"
    }

    let output = """

    ===== ScreenTextWindow SegmentDocument JSON BEGIN =====
    \(json)
    ===== ScreenTextWindow SegmentDocument JSON END =====

    """
    FileHandle.standardError.write(Data(output.utf8))
}
```

- [ ] **Step 5: Run a compile check**

Run:

```bash
xcodebuild -project falsoai-lens.xcodeproj -scheme falsoai-lens -configuration Debug build
```

Expected: remaining failures, if any, should be in smoke checks or obsolete helper methods.

---

### Task 3: Update Stub Smoke Checks

**Files:**
- Modify: `falsoai-lens/Pipelines/Vision/Services/StubScreenTextWindowAnalyzer.swift`

- [ ] **Step 1: Replace `sampleWindow` with `sampleDocument`**

Add a helper that builds the LLM-facing document directly:

```swift
private static func sampleDocument(segments: [ScreenTextWindowSegmentDTO] = []) -> ScreenTextWindowSegmentDocument {
    ScreenTextWindowSegmentDocument(
        window: ScreenTextWindowMetadataDTO(
            id: UUID(),
            sessionID: UUID(),
            sequenceNumber: 7,
            startedAt: Date(timeIntervalSince1970: 0),
            endedAt: Date(timeIntervalSince1970: 300),
            durationSeconds: 300,
            displayCount: segments.isEmpty ? 0 : 1,
            encounterCount: segments.reduce(0) { $0 + $1.lineCount },
            segmentCount: segments.count
        ),
        segments: segments
    )
}
```

- [ ] **Step 2: Replace `sampleEncounter` with `sampleSegment`**

```swift
private static func sampleSegment(text: String, role: ScreenTextStructureRole = .unknown) -> ScreenTextWindowSegmentDTO {
    ScreenTextWindowSegmentDTO(
        id: "display-0-\(role.rawValue)-\(text)",
        displayID: 1,
        displayIndex: 0,
        role: role,
        bounds: ScreenTextWindowBoundsDTO(x: 0, y: 0, width: 100, height: 20),
        text: text,
        lineCount: 1,
        totalSightingCount: 3,
        firstSightedAt: Date(timeIntervalSince1970: 10),
        lastSightedAt: Date(timeIntervalSince1970: 20),
        isRepeatedUI: false
    )
}
```

- [ ] **Step 3: Update identity smoke check**

Call:

```swift
let document = sampleDocument(segments: [sampleSegment(text: "hello")])
let analysis = try? await analyzer.analyze(document)
```

Assert against `document.window`, not `window`.

- [ ] **Step 4: Update summary smoke check**

Call:

```swift
let document = sampleDocument(segments: [
    sampleSegment(text: "alpha"),
    sampleSegment(text: "beta")
])
let analysis = try? await analyzer.analyze(document)
```

Assert the summary contains `"alpha"` and `"beta"`. If the summary label changes from `"Unique lines"` to another phrase, assert the new phrase exactly.

- [ ] **Step 5: Update empty document smoke check**

Call:

```swift
let document = sampleDocument()
let analysis = try? await analyzer.analyze(document)
```

Assert:

```swift
assert(analysis != nil, "Stub analyzer threw on empty document")
assert(analysis?.encounterCount == 0, "Stub analysis encounterCount mismatch on empty document")
assert(analysis?.summaryMarkdown.contains("_(none)_") == true,
       "Stub summary did not mark empty segments")
```

---

### Task 4: Remove Obsolete Segment Preparation from LLM Preparation Service

**Files:**
- Modify: `falsoai-lens/Pipelines/Vision/Services/ScreenTextLLMPreparationService.swift`

- [ ] **Step 1: Search for remaining call sites**

Run:

```bash
rg -n "prepareSegmentDocument|prepareSegmentDocumentJSON|segmentDocumentExporter" falsoai-lens/Pipelines/Vision
```

Expected before cleanup: references in `ScreenTextLLMPreparationService.swift` only.

- [ ] **Step 2: Remove unused stored property**

Delete:

```swift
private let segmentDocumentExporter: ScreenTextWindowSegmentDocumentExporter
```

- [ ] **Step 3: Simplify initializer**

Remove the `segmentDocumentExporter` parameter and assignment. The initializer should keep only:

```swift
init(
    exporter: ScreenTextLLMExporter = ScreenTextLLMExporter(),
    classifier: any ScreenTextStructureClassifying = HeuristicScreenTextStructureClassifier(),
    promptExporter: ScreenTextStructuredPromptExporter = ScreenTextStructuredPromptExporter()
) {
    self.exporter = exporter
    self.classifier = classifier
    self.promptExporter = promptExporter
}
```

- [ ] **Step 4: Delete obsolete methods**

Delete:

```swift
func prepareSegmentDocument(_ window: ScreenTextWindow) -> ScreenTextWindowSegmentDocument {
    segmentDocumentExporter.export(window)
}

func prepareSegmentDocumentJSON(_ window: ScreenTextWindow) throws -> String {
    let document = segmentDocumentExporter.export(window)
    return try segmentDocumentExporter.compactJSON(document)
}
```

- [ ] **Step 5: Re-run call-site search**

Run:

```bash
rg -n "prepareSegmentDocument|prepareSegmentDocumentJSON|segmentDocumentExporter" falsoai-lens/Pipelines/Vision
```

Expected: only `segmentDocumentExporter` references in `RealtimeScreenTextPipeline.swift` and `ScreenTextWindowSegmentDocumentExporter.swift`; no `prepareSegmentDocument` references.

---

### Task 5: Final Verification and Commit

**Files:**
- Validate all modified files.

- [ ] **Step 1: Check analyzer call sites**

Run:

```bash
rg -n "func analyze\\(|analyze\\(" falsoai-lens/Pipelines/Vision
```

Expected:
- Protocol has `func analyze(_ document: ScreenTextWindowSegmentDocument)`.
- Stub has `func analyze(_ document: ScreenTextWindowSegmentDocument)`.
- Pipeline calls `analyzer.analyze(segmentDocument)`.
- No analyzer call passes `ScreenTextWindow`.

- [ ] **Step 2: Check the LLM payload is exported once per sealed window**

Run:

```bash
rg -n "segmentDocumentExporter.export\\(|logDebugSegmentDocument" falsoai-lens/Pipelines/Vision/Services/RealtimeScreenTextPipeline.swift
```

Expected:
- One `segmentDocumentExporter.export(window)` in `sealAndFlushWindow(at:)`.
- `logDebugSegmentDocument(segmentDocument)`.
- `logDebugSegmentDocument(_ document: ScreenTextWindowSegmentDocument)`.

- [ ] **Step 3: Build**

Run:

```bash
xcodebuild -project falsoai-lens.xcodeproj -scheme falsoai-lens -configuration Debug build
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Review diff**

Run:

```bash
git diff -- falsoai-lens/Pipelines/Vision/Services/ScreenTextWindowAnalyzing.swift falsoai-lens/Pipelines/Vision/Services/StubScreenTextWindowAnalyzer.swift falsoai-lens/Pipelines/Vision/Services/RealtimeScreenTextPipeline.swift falsoai-lens/Pipelines/Vision/Services/ScreenTextLLMPreparationService.swift
```

Expected:
- Analyzer boundary uses `ScreenTextWindowSegmentDocument`.
- Pipeline constructs the document once.
- Stub no longer owns segment reduction.
- No unrelated formatting churn.

- [ ] **Step 5: Commit**

Run:

```bash
git add falsoai-lens/Pipelines/Vision/Services/ScreenTextWindowAnalyzing.swift falsoai-lens/Pipelines/Vision/Services/StubScreenTextWindowAnalyzer.swift falsoai-lens/Pipelines/Vision/Services/RealtimeScreenTextPipeline.swift falsoai-lens/Pipelines/Vision/Services/ScreenTextLLMPreparationService.swift
git commit -m "Pass segment documents to screen text analyzer"
```

Expected: one focused commit.

---

## Self-Review

- Spec coverage: The plan changes the analyzer input to the LLM-facing segment document, moves segment document construction to the pipeline boundary, preserves `ScreenTextWindow` upstream, and removes dead preparation code.
- Placeholder scan: No TBD/TODO/fill-in-later placeholders.
- Type consistency: `ScreenTextWindowSegmentDocument`, `ScreenTextWindowMetadataDTO`, and `ScreenTextWindowSegmentDTO` names match the current model files. `ScreenTextWindowAnalysis` remains unchanged and maps from `document.window`.
