# Screen Text LLM Exporter Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a deterministic adapter that converts cached screen-text structure into LLM-friendly anchored markdown, compact JSON, and bounded text chunks without adding inference, classification, or semantic labels.

**Architecture:** Keep `ScreenTextDocument` and `MultiDisplayScreenTextDocument` as the factual source of truth. Add a separate export model and exporter service that assigns stable short aliases, reading order, normalized bounds, and factual metrics derived only from OCR geometry and text. Consumers can pass exported markdown, JSON, or chunks to an LLM outside the screen-capture pipeline.

**Tech Stack:** Swift, Foundation, CoreGraphics, JSONEncoder, existing Vision screen-text models.

---

## Scope

This plan implements an LLM-friendly formatting layer only.

It does:

- Preserve factual OCR observations, lines, blocks, regions, display IDs, timestamps, bounds, confidence, and hashes.
- Add short references such as `d1.r2.b4.l1` so an LLM can cite screen text compactly.
- Add reading-order integers based on existing ordered arrays.
- Add normalized bounds alongside absolute pixel bounds.
- Add compact markdown, compact JSON, and chunk exports.

It does not:

- Add an LLM call.
- Add classification.
- Add semantic role inference such as `button`, `heading`, `ad`, or `warning`.
- Modify screen capture, OCR, layout grouping, memory caching, or notification behavior.

## File Structure

- Create `falsoai-lens/Pipelines/Vision/Models/ScreenTextLLMDocument.swift`
  - Owns export DTOs only.
  - Uses plain `Codable`, `Equatable`, and `Sendable` structs.
  - Stores compact aliases and factual geometry/text fields.

- Create `falsoai-lens/Pipelines/Vision/Services/ScreenTextLLMExporter.swift`
  - Converts `MultiDisplayScreenTextDocument` into `ScreenTextLLMDocument`.
  - Produces anchored markdown.
  - Produces compact JSON.
  - Produces bounded chunks.

- Create `/private/tmp/falsoai-lens-llm-exporter-tests/main.swift`
  - Temporary smoke harness for deterministic verification because the project has no configured test target.

- No changes to `ContentView.swift` in this plan.
  - UI preview can be added as a separate task after the exporter is stable.
  - Keeping the first pass API-only avoids mixing debugging display concerns with the formatter.

---

### Task 1: Add LLM Export DTOs

**Files:**

- Create: `falsoai-lens/Pipelines/Vision/Models/ScreenTextLLMDocument.swift`

- [ ] **Step 1: Create the export model file**

Use this exact file content:

```swift
import CoreGraphics
import Foundation

struct ScreenTextLLMDocument: Codable, Equatable, Sendable {
    let sourceDocumentID: UUID
    let capturedAt: Date
    let displayCount: Int
    let observationCount: Int
    let lineCount: Int
    let blockCount: Int
    let regionCount: Int
    let displays: [ScreenTextLLMDisplay]
}

struct ScreenTextLLMDisplay: Codable, Equatable, Sendable {
    let alias: String
    let displayID: UInt32
    let index: Int
    let capturedAt: Date
    let frameSize: ScreenTextLLMSize
    let frameHash: String
    let normalizedTextHash: String
    let layoutHash: String
    let text: String
    let regions: [ScreenTextLLMRegion]
    let blocks: [ScreenTextLLMBlock]
    let lines: [ScreenTextLLMLine]
    let observations: [ScreenTextLLMObservation]
}

struct ScreenTextLLMRegion: Codable, Equatable, Sendable {
    let alias: String
    let sourceID: UUID
    let readingOrder: Int
    let bounds: ScreenTextLLMBounds
    let normalizedBounds: ScreenTextLLMBounds
    let blockAliases: [String]
    let metrics: ScreenTextLLMMetrics
}

struct ScreenTextLLMBlock: Codable, Equatable, Sendable {
    let alias: String
    let sourceID: UUID
    let readingOrder: Int
    let text: String
    let bounds: ScreenTextLLMBounds
    let normalizedBounds: ScreenTextLLMBounds
    let lineAliases: [String]
    let metrics: ScreenTextLLMMetrics
}

struct ScreenTextLLMLine: Codable, Equatable, Sendable {
    let alias: String
    let sourceID: UUID
    let readingOrder: Int
    let text: String
    let bounds: ScreenTextLLMBounds
    let normalizedBounds: ScreenTextLLMBounds
    let observationAliases: [String]
    let metrics: ScreenTextLLMMetrics
}

struct ScreenTextLLMObservation: Codable, Equatable, Sendable {
    let alias: String
    let sourceID: UUID
    let readingOrder: Int
    let text: String
    let bounds: ScreenTextLLMBounds
    let normalizedBounds: ScreenTextLLMBounds
    let confidence: Float
    let metrics: ScreenTextLLMMetrics
}

struct ScreenTextLLMChunk: Codable, Equatable, Sendable {
    let alias: String
    let displayAlias: String
    let regionAliases: [String]
    let text: String
    let characterCount: Int
}

struct ScreenTextLLMBounds: Codable, Equatable, Sendable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double
}

struct ScreenTextLLMSize: Codable, Equatable, Sendable {
    let width: Double
    let height: Double
}

struct ScreenTextLLMMetrics: Codable, Equatable, Sendable {
    let characterCount: Int
    let wordCount: Int
    let areaRatio: Double
}
```

- [ ] **Step 2: Verify the new model compiles with the current source model**

Run:

```bash
xcrun swiftc \
  falsoai-lens/Pipelines/Vision/Models/ScreenTextDocument.swift \
  falsoai-lens/Pipelines/Vision/Models/ScreenTextLLMDocument.swift \
  -typecheck
```

Expected:

```text
No output and exit code 0.
```

- [ ] **Step 3: Commit**

```bash
git add falsoai-lens/Pipelines/Vision/Models/ScreenTextLLMDocument.swift
git commit -m "feat: add screen text llm export models"
```

---

### Task 2: Add the Deterministic Exporter

**Files:**

- Create: `falsoai-lens/Pipelines/Vision/Services/ScreenTextLLMExporter.swift`

- [ ] **Step 1: Create the exporter service**

Use this exact file content:

```swift
import CoreGraphics
import Foundation

struct ScreenTextLLMExporter {
    func export(_ source: MultiDisplayScreenTextDocument) -> ScreenTextLLMDocument {
        let displays = source.displays.enumerated().map { offset, display in
            exportDisplay(display, fallbackIndex: offset)
        }

        return ScreenTextLLMDocument(
            sourceDocumentID: source.id,
            capturedAt: source.capturedAt,
            displayCount: source.displays.count,
            observationCount: source.observationCount,
            lineCount: source.lineCount,
            blockCount: source.blockCount,
            regionCount: source.regionCount,
            displays: displays
        )
    }

    func anchoredMarkdown(from document: ScreenTextLLMDocument) -> String {
        var output: [String] = []
        output.append("# Screen Text")
        output.append("")
        output.append("- capturedAt: \(document.capturedAt.ISO8601Format())")
        output.append("- displayCount: \(document.displayCount)")
        output.append("- observationCount: \(document.observationCount)")
        output.append("- lineCount: \(document.lineCount)")
        output.append("- blockCount: \(document.blockCount)")
        output.append("- regionCount: \(document.regionCount)")
        output.append("")

        for display in document.displays {
            output.append("## \(display.alias)")
            output.append("")
            output.append("- displayID: \(display.displayID)")
            output.append("- index: \(display.index)")
            output.append("- frameSize: \(Int(display.frameSize.width))x\(Int(display.frameSize.height))")
            output.append("- frameHash: \(display.frameHash)")
            output.append("- normalizedTextHash: \(display.normalizedTextHash)")
            output.append("- layoutHash: \(display.layoutHash)")
            output.append("")

            if display.regions.isEmpty {
                output.append("_No OCR text detected._")
                output.append("")
                continue
            }

            for region in display.regions {
                output.append("### \(region.alias)")
                output.append("")
                output.append("- order: \(region.readingOrder)")
                output.append("- bounds: \(formatBounds(region.bounds))")
                output.append("- normalizedBounds: \(formatBounds(region.normalizedBounds))")
                output.append("- blockAliases: \(region.blockAliases.joined(separator: ", "))")
                output.append("")

                let blocks = display.blocks.filter { region.blockAliases.contains($0.alias) }
                for block in blocks {
                    output.append("#### \(block.alias)")
                    output.append("")
                    output.append("- order: \(block.readingOrder)")
                    output.append("- bounds: \(formatBounds(block.bounds))")
                    output.append("- lineAliases: \(block.lineAliases.joined(separator: ", "))")
                    output.append("")
                    output.append(block.text)
                    output.append("")
                }
            }
        }

        return output.joined(separator: "\n")
    }

    func compactJSON(from document: ScreenTextLLMDocument) throws -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(document)
        return String(decoding: data, as: UTF8.self)
    }

    func chunks(from document: ScreenTextLLMDocument, maxCharacters: Int = 6_000) -> [ScreenTextLLMChunk] {
        precondition(maxCharacters > 0, "maxCharacters must be greater than zero")

        var chunks: [ScreenTextLLMChunk] = []
        var chunkIndex = 1

        for display in document.displays {
            var currentLines: [String] = []
            var currentRegionAliases: [String] = []
            var currentCount = 0

            func flushCurrentChunk() {
                guard !currentLines.isEmpty else { return }

                let text = currentLines.joined(separator: "\n")
                chunks.append(
                    ScreenTextLLMChunk(
                        alias: "\(display.alias).c\(chunkIndex)",
                        displayAlias: display.alias,
                        regionAliases: currentRegionAliases,
                        text: text,
                        characterCount: text.count
                    )
                )
                chunkIndex += 1
                currentLines.removeAll()
                currentRegionAliases.removeAll()
                currentCount = 0
            }

            for region in display.regions {
                let blocks = display.blocks.filter { region.blockAliases.contains($0.alias) }
                let regionText = blocks
                    .map { "[\($0.alias)] \($0.text)" }
                    .joined(separator: "\n")

                guard !regionText.isEmpty else {
                    continue
                }

                let additionalCount = regionText.count + (currentLines.isEmpty ? 0 : 1)
                if currentCount > 0 && currentCount + additionalCount > maxCharacters {
                    flushCurrentChunk()
                }

                if regionText.count > maxCharacters {
                    let splitLines = splitOversizedText(regionText, maxCharacters: maxCharacters)
                    for line in splitLines {
                        if currentCount > 0 {
                            flushCurrentChunk()
                        }
                        currentLines.append(line)
                        currentRegionAliases.append(region.alias)
                        currentCount = line.count
                        flushCurrentChunk()
                    }
                } else {
                    currentLines.append(regionText)
                    if !currentRegionAliases.contains(region.alias) {
                        currentRegionAliases.append(region.alias)
                    }
                    currentCount += additionalCount
                }
            }

            flushCurrentChunk()
        }

        return chunks
    }

    private func exportDisplay(_ source: DisplayScreenTextDocument, fallbackIndex: Int) -> ScreenTextLLMDisplay {
        let displayAlias = "d\(source.index + 1)"
        let frameSize = source.document.frameSize

        let observationAliases = Dictionary(
            uniqueKeysWithValues: source.document.observations.enumerated().map { offset, observation in
                (observation.id, "\(displayAlias).o\(offset + 1)")
            }
        )

        let lineAliases = Dictionary(
            uniqueKeysWithValues: source.document.lines.enumerated().map { offset, line in
                (line.id, "\(displayAlias).l\(offset + 1)")
            }
        )

        let blockAliases = Dictionary(
            uniqueKeysWithValues: source.document.blocks.enumerated().map { offset, block in
                (block.id, "\(displayAlias).b\(offset + 1)")
            }
        )

        let observations = source.document.observations.enumerated().map { offset, observation in
            ScreenTextLLMObservation(
                alias: observationAliases[observation.id] ?? "\(displayAlias).o\(offset + 1)",
                sourceID: observation.id,
                readingOrder: offset + 1,
                text: observation.text,
                bounds: bounds(from: observation.boundingBox),
                normalizedBounds: normalizedBounds(from: observation.boundingBox, frameSize: frameSize),
                confidence: observation.confidence,
                metrics: metrics(text: observation.text, bounds: observation.boundingBox, frameSize: frameSize)
            )
        }

        let lines = source.document.lines.enumerated().map { offset, line in
            ScreenTextLLMLine(
                alias: lineAliases[line.id] ?? "\(displayAlias).l\(offset + 1)",
                sourceID: line.id,
                readingOrder: offset + 1,
                text: line.text,
                bounds: bounds(from: line.boundingBox),
                normalizedBounds: normalizedBounds(from: line.boundingBox, frameSize: frameSize),
                observationAliases: line.observationIDs.compactMap { observationAliases[$0] },
                metrics: metrics(text: line.text, bounds: line.boundingBox, frameSize: frameSize)
            )
        }

        let blocks = source.document.blocks.enumerated().map { offset, block in
            ScreenTextLLMBlock(
                alias: blockAliases[block.id] ?? "\(displayAlias).b\(offset + 1)",
                sourceID: block.id,
                readingOrder: offset + 1,
                text: block.text,
                bounds: bounds(from: block.boundingBox),
                normalizedBounds: normalizedBounds(from: block.boundingBox, frameSize: frameSize),
                lineAliases: block.lineIDs.compactMap { lineAliases[$0] },
                metrics: metrics(text: block.text, bounds: block.boundingBox, frameSize: frameSize)
            )
        }

        let regions = source.document.regions.enumerated().map { offset, region in
            ScreenTextLLMRegion(
                alias: "\(displayAlias).r\(offset + 1)",
                sourceID: region.id,
                readingOrder: offset + 1,
                bounds: bounds(from: region.boundingBox),
                normalizedBounds: normalizedBounds(from: region.boundingBox, frameSize: frameSize),
                blockAliases: region.blockIDs.compactMap { blockAliases[$0] },
                metrics: metrics(text: "", bounds: region.boundingBox, frameSize: frameSize)
            )
        }

        return ScreenTextLLMDisplay(
            alias: displayAlias,
            displayID: source.displayID,
            index: fallbackIndex,
            capturedAt: source.document.capturedAt,
            frameSize: ScreenTextLLMSize(width: frameSize.width, height: frameSize.height),
            frameHash: source.document.frameHash,
            normalizedTextHash: source.document.normalizedTextHash,
            layoutHash: source.document.layoutHash,
            text: source.document.recognizedText,
            regions: regions,
            blocks: blocks,
            lines: lines,
            observations: observations
        )
    }

    private func bounds(from rect: CGRect) -> ScreenTextLLMBounds {
        ScreenTextLLMBounds(
            x: rect.origin.x,
            y: rect.origin.y,
            width: rect.width,
            height: rect.height
        )
    }

    private func normalizedBounds(from rect: CGRect, frameSize: CGSize) -> ScreenTextLLMBounds {
        guard frameSize.width > 0, frameSize.height > 0 else {
            return ScreenTextLLMBounds(x: 0, y: 0, width: 0, height: 0)
        }

        return ScreenTextLLMBounds(
            x: rect.origin.x / frameSize.width,
            y: rect.origin.y / frameSize.height,
            width: rect.width / frameSize.width,
            height: rect.height / frameSize.height
        )
    }

    private func metrics(text: String, bounds: CGRect, frameSize: CGSize) -> ScreenTextLLMMetrics {
        let frameArea = frameSize.width * frameSize.height
        let areaRatio = frameArea > 0 ? (bounds.width * bounds.height) / frameArea : 0

        return ScreenTextLLMMetrics(
            characterCount: text.count,
            wordCount: text.split(whereSeparator: \.isWhitespace).count,
            areaRatio: areaRatio
        )
    }

    private func formatBounds(_ bounds: ScreenTextLLMBounds) -> String {
        let values = [bounds.x, bounds.y, bounds.width, bounds.height].map { value in
            String(format: "%.4f", value)
        }

        return "[x: \(values[0]), y: \(values[1]), w: \(values[2]), h: \(values[3])]"
    }

    private func splitOversizedText(_ text: String, maxCharacters: Int) -> [String] {
        var result: [String] = []
        var current = ""

        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let next = String(line)
            let separatorCount = current.isEmpty ? 0 : 1

            if !current.isEmpty && current.count + separatorCount + next.count > maxCharacters {
                result.append(current)
                current = ""
            }

            if next.count > maxCharacters {
                let characters = Array(next)
                var start = 0
                while start < characters.count {
                    let end = min(start + maxCharacters, characters.count)
                    result.append(String(characters[start..<end]))
                    start = end
                }
            } else {
                current = current.isEmpty ? next : "\(current)\n\(next)"
            }
        }

        if !current.isEmpty {
            result.append(current)
        }

        return result
    }
}
```

- [ ] **Step 2: Typecheck the exporter**

Run:

```bash
xcrun swiftc \
  falsoai-lens/Pipelines/Vision/Models/ScreenTextDocument.swift \
  falsoai-lens/Pipelines/Vision/Models/ScreenTextLLMDocument.swift \
  falsoai-lens/Pipelines/Vision/Services/ScreenTextLLMExporter.swift \
  -typecheck
```

Expected:

```text
No output and exit code 0.
```

- [ ] **Step 3: Commit**

```bash
git add \
  falsoai-lens/Pipelines/Vision/Models/ScreenTextLLMDocument.swift \
  falsoai-lens/Pipelines/Vision/Services/ScreenTextLLMExporter.swift
git commit -m "feat: export screen text for llm context"
```

---

### Task 3: Add a Temporary Smoke Harness

**Files:**

- Create: `/private/tmp/falsoai-lens-llm-exporter-tests/main.swift`

- [ ] **Step 1: Create the smoke harness**

Create `/private/tmp/falsoai-lens-llm-exporter-tests/main.swift` with:

```swift
import CoreGraphics
import Foundation

func assert(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        fatalError(message)
    }
}

let observation1 = ScreenTextObservation(
    text: "Checkout",
    boundingBox: CGRect(x: 20, y: 20, width: 160, height: 40),
    confidence: 0.98
)

let observation2 = ScreenTextObservation(
    text: "Total $42.00",
    boundingBox: CGRect(x: 20, y: 80, width: 240, height: 40),
    confidence: 0.96
)

let line1 = ScreenTextLine(
    text: "Checkout",
    boundingBox: observation1.boundingBox,
    observationIDs: [observation1.id]
)

let line2 = ScreenTextLine(
    text: "Total $42.00",
    boundingBox: observation2.boundingBox,
    observationIDs: [observation2.id]
)

let block = ScreenTextBlock(
    text: "Checkout\nTotal $42.00",
    boundingBox: observation1.boundingBox.union(observation2.boundingBox),
    lineIDs: [line1.id, line2.id]
)

let region = ScreenTextRegion(
    boundingBox: block.boundingBox,
    blockIDs: [block.id]
)

let document = ScreenTextDocument(
    capturedAt: Date(timeIntervalSince1970: 1_772_493_600),
    frameSize: CGSize(width: 800, height: 600),
    frameHash: "frame-hash",
    normalizedTextHash: "text-hash",
    layoutHash: "layout-hash",
    observations: [observation1, observation2],
    lines: [line1, line2],
    blocks: [block],
    regions: [region]
)

let display = DisplayScreenTextDocument(
    displayID: 7,
    index: 0,
    document: document
)

let multiDisplayDocument = MultiDisplayScreenTextDocument(
    capturedAt: document.capturedAt,
    displays: [display]
)

let exporter = ScreenTextLLMExporter()
let exported = exporter.export(multiDisplayDocument)

assert(exported.displayCount == 1, "Expected one display")
assert(exported.observationCount == 2, "Expected two observations")
assert(exported.lineCount == 2, "Expected two lines")
assert(exported.blockCount == 1, "Expected one block")
assert(exported.regionCount == 1, "Expected one region")

let exportedDisplay = exported.displays[0]
assert(exportedDisplay.alias == "d1", "Expected first display alias to be d1")
assert(exportedDisplay.regions[0].alias == "d1.r1", "Expected first region alias to be d1.r1")
assert(exportedDisplay.blocks[0].alias == "d1.b1", "Expected first block alias to be d1.b1")
assert(exportedDisplay.lines[0].alias == "d1.l1", "Expected first line alias to be d1.l1")
assert(exportedDisplay.observations[0].alias == "d1.o1", "Expected first observation alias to be d1.o1")

let normalized = exportedDisplay.blocks[0].normalizedBounds
assert(abs(normalized.x - 0.025) < 0.0001, "Expected normalized x to be derived from frame width")
assert(abs(normalized.y - 0.0333) < 0.0001, "Expected normalized y to be derived from frame height")

let markdown = exporter.anchoredMarkdown(from: exported)
assert(markdown.contains("# Screen Text"), "Expected markdown title")
assert(markdown.contains("## d1"), "Expected display heading")
assert(markdown.contains("### d1.r1"), "Expected region heading")
assert(markdown.contains("#### d1.b1"), "Expected block heading")
assert(markdown.contains("Checkout\nTotal $42.00"), "Expected block text in markdown")

let json = try exporter.compactJSON(from: exported)
assert(json.contains("\"alias\":\"d1\""), "Expected compact JSON to include display alias")
assert(json.contains("\"frameHash\":\"frame-hash\""), "Expected compact JSON to include frame hash")

let chunks = exporter.chunks(from: exported, maxCharacters: 80)
assert(chunks.count == 1, "Expected one chunk")
assert(chunks[0].alias == "d1.c1", "Expected first chunk alias")
assert(chunks[0].text.contains("[d1.b1] Checkout"), "Expected chunk to include anchored block text")

print("Screen text LLM exporter checks passed")
```

- [ ] **Step 2: Run the smoke harness**

Run:

```bash
mkdir -p /private/tmp/falsoai-lens-llm-exporter-tests
xcrun swiftc \
  falsoai-lens/Pipelines/Vision/Models/ScreenTextDocument.swift \
  falsoai-lens/Pipelines/Vision/Models/ScreenTextLLMDocument.swift \
  falsoai-lens/Pipelines/Vision/Services/ScreenTextLLMExporter.swift \
  /private/tmp/falsoai-lens-llm-exporter-tests/main.swift \
  -o /private/tmp/falsoai-lens-llm-exporter-tests/run
/private/tmp/falsoai-lens-llm-exporter-tests/run
```

Expected:

```text
Screen text LLM exporter checks passed
```

- [ ] **Step 3: Remove no project files**

The smoke harness lives under `/private/tmp`, so no repository cleanup is required for this task.

---

### Task 4: Build the App

**Files:**

- Read-only verification of project build settings and all synchronized Swift sources.

- [ ] **Step 1: Run the Debug build**

Run:

```bash
xcodebuild -project falsoai-lens.xcodeproj -scheme falsoai-lens -configuration Debug build
```

Expected:

```text
** BUILD SUCCEEDED **
```

Known warnings that may still appear and are outside this plan:

```text
reference to captured var 'analyzer' in concurrently-executing code; this is an error in Swift 6
Run script build phase 'Re-sign bundled whisper-cli' will be run during every build because it does not specify any outputs.
```

- [ ] **Step 2: Commit build-verified exporter**

```bash
git status --short
git add \
  falsoai-lens/Pipelines/Vision/Models/ScreenTextLLMDocument.swift \
  falsoai-lens/Pipelines/Vision/Services/ScreenTextLLMExporter.swift
git commit -m "test: verify screen text llm exporter"
```

If Task 2 already committed both files and there are no repository changes from Task 4, skip this commit and record the build command output in the task notes.

---

## Self-Review

- Spec coverage:
  - The plan keeps capture/OCR/layout/memory untouched.
  - The plan adds deterministic formatting only.
  - The plan supports markdown, JSON, and chunks.
  - The plan exposes aliases, reading order, normalized bounds, and factual metrics.
  - The plan does not add LLM calls, classification, semantic role labels, or inference.

- Placeholder scan:
  - No `TBD` markers.
  - No unspecified validation steps.
  - Every code-producing step includes concrete file content.

- Type consistency:
  - `ScreenTextLLMExporter.export(_:)` returns `ScreenTextLLMDocument`.
  - `anchoredMarkdown(from:)`, `compactJSON(from:)`, and `chunks(from:maxCharacters:)` all consume `ScreenTextLLMDocument`.
  - DTO names match across the model file, exporter, and smoke harness.
