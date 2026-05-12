# Screen Text Structure Classifier Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an on-demand structural classifier that annotates LLM-exported screen text with layout roles such as heading, paragraph, button-like, form label, and table cell without adding manipulation, risk, or intent classification.

**Architecture:** Keep capture, OCR, realtime sampling, GRDB snapshot caching, and factual LLM export unchanged. Add a new LLM-preparation layer after `ScreenTextLLMExporter` that produces derived structure annotations and a structured markdown prompt. Do not persist structure annotations in the first pass; regenerate them from cached or latest factual screen text whenever LLM input is prepared.

**Tech Stack:** Swift, Foundation, existing screen text OCR models, existing `ScreenTextLLMExporter`, Swift concurrency-compatible value types.

---

## Scope

This plan implements only structural text organization for LLM analysis.

It does:

- Annotate exported screen-text blocks with UI/document roles.
- Keep annotations linked to existing aliases such as `d1.b2`.
- Produce a structured markdown prompt that combines factual text with structural hints.
- Keep all classifier output derived, local, deterministic, and cheap to recompute.
- Add smoke checks through a temporary Swift harness because the app has no configured test target.

It does not:

- Add manipulation classification.
- Add risk scoring.
- Add an LLM call.
- Add persistence for classifier output.
- Modify OCR, capture, cache deduplication, or five-minute encounter memory.
- Change `RealtimeScreenTextSnapshotRecord` or GRDB migrations.

## Layer Placement

The classifier belongs after factual LLM export and before prompt construction:

```text
ScreenCaptureService
  -> OCRService
  -> MultiDisplayScreenTextDocument
  -> ScreenTextLLMExporter
  -> ScreenTextStructureClassifier
  -> ScreenTextStructuredPromptExporter
  -> LLM analysis
```

The durable cache remains below the classifier:

```text
RealtimeScreenTextSnapshot / RealtimeScreenTextCache
  stores factual text, hashes, counts, markdownExport, compactJSONExport

ScreenTextStructureClassifier
  recomputes derived annotations on demand
```

## File Structure

- Create `falsoai-lens/Pipelines/Vision/Models/ScreenTextStructureAnnotation.swift`
  - Owns structural role enums, target kind enum, annotation DTO, and structured document DTO.

- Create `falsoai-lens/Pipelines/Vision/Services/ScreenTextStructureClassifier.swift`
  - Defines the `ScreenTextStructureClassifying` protocol.
  - Implements `HeuristicScreenTextStructureClassifier`.
  - Classifies blocks only in the first pass.

- Create `falsoai-lens/Pipelines/Vision/Services/ScreenTextStructuredPromptExporter.swift`
  - Converts a `ScreenTextStructuredLLMDocument` into compact LLM-ready markdown.

- Create `falsoai-lens/Pipelines/Vision/Services/ScreenTextLLMPreparationService.swift`
  - Small orchestration service that runs factual export, structural classification, and structured prompt export together.
  - This is the integration point for future LLM analysis.

- Create `/private/tmp/falsoai-lens-screen-text-structure-classifier-tests/main.swift`
  - Temporary smoke harness for deterministic classifier and prompt-export checks.

- No changes to `RealtimeScreenTextSampler.swift`
  - It should keep generating the existing factual `markdownExport` and `compactJSONExport`.

- No changes to `RealtimeScreenTextCache.swift`
  - Structure annotations are not cached in the first pass.

---

### Task 1: Add Structure Annotation Models

**Files:**

- Create: `falsoai-lens/Pipelines/Vision/Models/ScreenTextStructureAnnotation.swift`

- [ ] **Step 1: Create the model file**

Create `falsoai-lens/Pipelines/Vision/Models/ScreenTextStructureAnnotation.swift`:

```swift
import Foundation

enum ScreenTextStructureRole: String, Codable, CaseIterable, Equatable, Sendable {
    case heading
    case paragraph
    case listItem
    case buttonLike
    case linkLike
    case navigation
    case formLabel
    case formValue
    case inputPlaceholder
    case tableHeader
    case tableCell
    case dialogTitle
    case dialogBody
    case toastOrBanner
    case chatMessage
    case codeOrLog
    case priceOrNumber
    case metadata
    case unknown
}

enum ScreenTextStructureTargetKind: String, Codable, Equatable, Sendable {
    case block
}

struct ScreenTextStructureAnnotation: Codable, Equatable, Sendable {
    let alias: String
    let targetKind: ScreenTextStructureTargetKind
    let role: ScreenTextStructureRole
    let confidence: Double
    let reasons: [String]

    nonisolated init(
        alias: String,
        targetKind: ScreenTextStructureTargetKind,
        role: ScreenTextStructureRole,
        confidence: Double,
        reasons: [String]
    ) {
        self.alias = alias
        self.targetKind = targetKind
        self.role = role
        self.confidence = min(max(confidence, 0), 1)
        self.reasons = reasons
    }
}

struct ScreenTextStructuredLLMDocument: Codable, Equatable, Sendable {
    let source: ScreenTextLLMDocument
    let classifierID: String
    let classifierVersion: String
    let generatedAt: Date
    let annotations: [ScreenTextStructureAnnotation]

    nonisolated init(
        source: ScreenTextLLMDocument,
        classifierID: String,
        classifierVersion: String,
        generatedAt: Date = Date(),
        annotations: [ScreenTextStructureAnnotation]
    ) {
        self.source = source
        self.classifierID = classifierID
        self.classifierVersion = classifierVersion
        self.generatedAt = generatedAt
        self.annotations = annotations
    }

    func annotation(for alias: String) -> ScreenTextStructureAnnotation? {
        annotations.first { $0.alias == alias }
    }
}
```

- [ ] **Step 2: Typecheck the model with the existing LLM DTOs**

Run:

```bash
xcrun swiftc \
  falsoai-lens/Pipelines/Vision/Models/ScreenTextLLMDocument.swift \
  falsoai-lens/Pipelines/Vision/Models/ScreenTextStructureAnnotation.swift \
  -typecheck
```

Expected: no output and exit code `0`.

- [ ] **Step 3: Commit**

```bash
git add falsoai-lens/Pipelines/Vision/Models/ScreenTextStructureAnnotation.swift
git commit -m "feat: add screen text structure annotation models"
```

---

### Task 2: Add The Heuristic Structure Classifier

**Files:**

- Create: `falsoai-lens/Pipelines/Vision/Services/ScreenTextStructureClassifier.swift`
- Uses: `falsoai-lens/Pipelines/Vision/Models/ScreenTextLLMDocument.swift`
- Uses: `falsoai-lens/Pipelines/Vision/Models/ScreenTextStructureAnnotation.swift`

- [ ] **Step 1: Create the classifier service**

Create `falsoai-lens/Pipelines/Vision/Services/ScreenTextStructureClassifier.swift`:

```swift
import Foundation

protocol ScreenTextStructureClassifying: Sendable {
    func classify(_ document: ScreenTextLLMDocument) -> ScreenTextStructuredLLMDocument
}

struct HeuristicScreenTextStructureClassifier: ScreenTextStructureClassifying {
    let classifierID = "heuristic-screen-text-structure"
    let classifierVersion = "1"

    func classify(_ document: ScreenTextLLMDocument) -> ScreenTextStructuredLLMDocument {
        let annotations = document.displays.flatMap { display in
            display.blocks.map { block in
                classifyBlock(block, in: display)
            }
        }

        return ScreenTextStructuredLLMDocument(
            source: document,
            classifierID: classifierID,
            classifierVersion: classifierVersion,
            annotations: annotations
        )
    }

    private func classifyBlock(
        _ block: ScreenTextLLMBlock,
        in display: ScreenTextLLMDisplay
    ) -> ScreenTextStructureAnnotation {
        let text = block.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowercaseText = text.lowercased()
        let wordCount = block.metrics.wordCount
        let characterCount = block.metrics.characterCount
        let bounds = block.normalizedBounds

        if text.isEmpty {
            return annotation(
                block,
                role: .unknown,
                confidence: 0.2,
                reasons: ["empty block text"]
            )
        }

        if isCodeOrLog(text) {
            return annotation(
                block,
                role: .codeOrLog,
                confidence: 0.78,
                reasons: ["contains code or log punctuation patterns"]
            )
        }

        if isPriceOrNumber(text) {
            return annotation(
                block,
                role: .priceOrNumber,
                confidence: 0.74,
                reasons: ["contains currency, percentage, or numeric-heavy content"]
            )
        }

        if isButtonLike(lowercaseText, wordCount: wordCount, bounds: bounds) {
            return annotation(
                block,
                role: .buttonLike,
                confidence: 0.76,
                reasons: ["short action-like text", "compact block bounds"]
            )
        }

        if isLinkLike(lowercaseText, wordCount: wordCount) {
            return annotation(
                block,
                role: .linkLike,
                confidence: 0.7,
                reasons: ["short navigational or link-like text"]
            )
        }

        if isNavigationLike(lowercaseText, wordCount: wordCount, bounds: bounds) {
            return annotation(
                block,
                role: .navigation,
                confidence: 0.68,
                reasons: ["short text near a navigation edge"]
            )
        }

        if isFormLabel(text, wordCount: wordCount) {
            return annotation(
                block,
                role: .formLabel,
                confidence: 0.72,
                reasons: ["short label-like text"]
            )
        }

        if isInputPlaceholder(lowercaseText, wordCount: wordCount) {
            return annotation(
                block,
                role: .inputPlaceholder,
                confidence: 0.68,
                reasons: ["matches common placeholder wording"]
            )
        }

        if isTableHeader(text, wordCount: wordCount, bounds: bounds) {
            return annotation(
                block,
                role: .tableHeader,
                confidence: 0.64,
                reasons: ["short header-like text near upper area"]
            )
        }

        if isChatMessage(text, characterCount: characterCount, bounds: bounds) {
            return annotation(
                block,
                role: .chatMessage,
                confidence: 0.62,
                reasons: ["message-length text in conversation-like horizontal bounds"]
            )
        }

        if isHeadingLike(text, wordCount: wordCount, bounds: bounds, display: display) {
            return annotation(
                block,
                role: .heading,
                confidence: 0.72,
                reasons: ["short prominent text", "appears high or early in reading order"]
            )
        }

        if isMetadata(lowercaseText, wordCount: wordCount) {
            return annotation(
                block,
                role: .metadata,
                confidence: 0.64,
                reasons: ["date, time, status, or small descriptive metadata pattern"]
            )
        }

        if characterCount >= 90 || wordCount >= 14 {
            return annotation(
                block,
                role: .paragraph,
                confidence: 0.7,
                reasons: ["long prose-like block"]
            )
        }

        if wordCount <= 8 {
            return annotation(
                block,
                role: .tableCell,
                confidence: 0.48,
                reasons: ["short standalone text without stronger structural signal"]
            )
        }

        return annotation(
            block,
            role: .unknown,
            confidence: 0.4,
            reasons: ["no strong structural rule matched"]
        )
    }

    private func annotation(
        _ block: ScreenTextLLMBlock,
        role: ScreenTextStructureRole,
        confidence: Double,
        reasons: [String]
    ) -> ScreenTextStructureAnnotation {
        ScreenTextStructureAnnotation(
            alias: block.alias,
            targetKind: .block,
            role: role,
            confidence: confidence,
            reasons: reasons
        )
    }

    private func isButtonLike(
        _ lowercaseText: String,
        wordCount: Int,
        bounds: ScreenTextLLMBounds
    ) -> Bool {
        guard wordCount <= 5, bounds.width <= 0.45, bounds.height <= 0.12 else {
            return false
        }

        let exactActions: Set<String> = [
            "ok",
            "cancel",
            "done",
            "save",
            "send",
            "submit",
            "continue",
            "next",
            "back",
            "close",
            "apply",
            "confirm",
            "sign in",
            "log in",
            "create account",
            "get started",
            "learn more"
        ]

        if exactActions.contains(lowercaseText) {
            return true
        }

        return lowercaseText.hasPrefix("save ")
            || lowercaseText.hasPrefix("add ")
            || lowercaseText.hasPrefix("create ")
            || lowercaseText.hasPrefix("open ")
            || lowercaseText.hasPrefix("view ")
            || lowercaseText.hasPrefix("start ")
    }

    private func isLinkLike(_ lowercaseText: String, wordCount: Int) -> Bool {
        guard wordCount <= 7 else { return false }

        return lowercaseText.hasPrefix("http://")
            || lowercaseText.hasPrefix("https://")
            || lowercaseText.contains("www.")
            || lowercaseText.contains(".com")
            || lowercaseText == "terms"
            || lowercaseText == "privacy"
            || lowercaseText == "forgot password?"
            || lowercaseText == "learn more"
    }

    private func isNavigationLike(
        _ lowercaseText: String,
        wordCount: Int,
        bounds: ScreenTextLLMBounds
    ) -> Bool {
        guard wordCount <= 4 else { return false }

        let nearTop = bounds.y <= 0.18
        let nearSide = bounds.x <= 0.18 || bounds.x + bounds.width >= 0.82
        let navWords: Set<String> = [
            "home",
            "search",
            "settings",
            "profile",
            "account",
            "dashboard",
            "inbox",
            "help",
            "files",
            "edit",
            "view",
            "window"
        ]

        return (nearTop || nearSide) && navWords.contains(lowercaseText)
    }

    private func isFormLabel(_ text: String, wordCount: Int) -> Bool {
        let lowercaseText = text.lowercased()
        guard wordCount <= 5 else { return false }

        if text.hasSuffix(":") {
            return true
        }

        let labelWords: Set<String> = [
            "name",
            "email",
            "password",
            "username",
            "phone",
            "address",
            "company",
            "title",
            "description",
            "search",
            "date",
            "amount"
        ]

        return labelWords.contains(lowercaseText)
    }

    private func isInputPlaceholder(_ lowercaseText: String, wordCount: Int) -> Bool {
        guard wordCount <= 8 else { return false }

        return lowercaseText.hasPrefix("enter ")
            || lowercaseText.hasPrefix("type ")
            || lowercaseText.hasPrefix("search ")
            || lowercaseText.hasPrefix("select ")
            || lowercaseText.hasPrefix("choose ")
            || lowercaseText.contains("placeholder")
    }

    private func isTableHeader(
        _ text: String,
        wordCount: Int,
        bounds: ScreenTextLLMBounds
    ) -> Bool {
        guard wordCount <= 4, bounds.y <= 0.35 else { return false }

        let lowercaseText = text.lowercased()
        let headerWords: Set<String> = [
            "status",
            "date",
            "name",
            "type",
            "amount",
            "total",
            "price",
            "owner",
            "created",
            "updated"
        ]

        return headerWords.contains(lowercaseText)
    }

    private func isChatMessage(
        _ text: String,
        characterCount: Int,
        bounds: ScreenTextLLMBounds
    ) -> Bool {
        guard characterCount >= 12, characterCount <= 280 else { return false }

        let hasSentencePunctuation = text.contains(".") || text.contains("?") || text.contains("!")
        let conversationWidth = bounds.width >= 0.25 && bounds.width <= 0.85
        let insetFromEdges = bounds.x >= 0.05 && bounds.x + bounds.width <= 0.95

        return hasSentencePunctuation && conversationWidth && insetFromEdges
    }

    private func isHeadingLike(
        _ text: String,
        wordCount: Int,
        bounds: ScreenTextLLMBounds,
        display: ScreenTextLLMDisplay
    ) -> Bool {
        guard wordCount <= 10 else { return false }

        let appearsHigh = bounds.y <= 0.28
        let appearsEarly = display.blocks.first?.alias == textBlockAlias(forText: text, in: display)
        let titleCaseOrShort = text.first?.isUppercase == true || wordCount <= 3

        return titleCaseOrShort && (appearsHigh || appearsEarly)
    }

    private func textBlockAlias(forText text: String, in display: ScreenTextLLMDisplay) -> String? {
        display.blocks.first { $0.text == text }?.alias
    }

    private func isMetadata(_ lowercaseText: String, wordCount: Int) -> Bool {
        guard wordCount <= 8 else { return false }

        if lowercaseText.contains("updated")
            || lowercaseText.contains("created")
            || lowercaseText.contains("edited")
            || lowercaseText.contains("version")
            || lowercaseText.contains("last seen") {
            return true
        }

        let hasTimeSeparator = lowercaseText.contains(":")
        let hasDateSeparator = lowercaseText.contains("/") || lowercaseText.contains("-")
        let hasDigit = lowercaseText.contains { $0.isNumber }

        return hasDigit && (hasTimeSeparator || hasDateSeparator)
    }

    private func isPriceOrNumber(_ text: String) -> Bool {
        let digitCount = text.filter(\.isNumber).count
        guard digitCount > 0 else { return false }

        if text.contains("$") || text.contains("USD") || text.contains("EUR") || text.contains("GBP") || text.contains("%") {
            return true
        }

        let nonWhitespaceCount = text.filter { !$0.isWhitespace }.count
        return nonWhitespaceCount > 0 && Double(digitCount) / Double(nonWhitespaceCount) >= 0.55
    }

    private func isCodeOrLog(_ text: String) -> Bool {
        let lowercaseText = text.lowercased()

        if lowercaseText.contains(" error ")
            || lowercaseText.hasPrefix("error")
            || lowercaseText.contains(" warning ")
            || lowercaseText.hasPrefix("warning")
            || lowercaseText.contains("exception")
            || lowercaseText.contains("stack trace") {
            return true
        }

        let codeTokens = ["{", "}", "();", "=>", "==", "!=", "let ", "var ", "func ", "import "]
        return codeTokens.contains { text.contains($0) }
    }
}
```

- [ ] **Step 2: Typecheck the classifier**

Run:

```bash
xcrun swiftc \
  falsoai-lens/Pipelines/Vision/Models/ScreenTextLLMDocument.swift \
  falsoai-lens/Pipelines/Vision/Models/ScreenTextStructureAnnotation.swift \
  falsoai-lens/Pipelines/Vision/Services/ScreenTextStructureClassifier.swift \
  -typecheck
```

Expected: no output and exit code `0`.

- [ ] **Step 3: Commit**

```bash
git add \
  falsoai-lens/Pipelines/Vision/Models/ScreenTextStructureAnnotation.swift \
  falsoai-lens/Pipelines/Vision/Services/ScreenTextStructureClassifier.swift
git commit -m "feat: add screen text structure classifier"
```

---

### Task 3: Add Structured Prompt Export

**Files:**

- Create: `falsoai-lens/Pipelines/Vision/Services/ScreenTextStructuredPromptExporter.swift`

- [ ] **Step 1: Create the prompt exporter**

Create `falsoai-lens/Pipelines/Vision/Services/ScreenTextStructuredPromptExporter.swift`:

```swift
import Foundation

struct ScreenTextStructuredPromptExporter {
    func markdown(from document: ScreenTextStructuredLLMDocument) -> String {
        var output: [String] = []

        output.append("# Screen Text Structure")
        output.append("")
        output.append("- capturedAt: \(document.source.capturedAt.ISO8601Format())")
        output.append("- displayCount: \(document.source.displayCount)")
        output.append("- observationCount: \(document.source.observationCount)")
        output.append("- lineCount: \(document.source.lineCount)")
        output.append("- blockCount: \(document.source.blockCount)")
        output.append("- regionCount: \(document.source.regionCount)")
        output.append("- classifier: \(document.classifierID)@\(document.classifierVersion)")
        output.append("- structureNote: Roles are deterministic layout hints derived from OCR text and geometry.")
        output.append("")

        for display in document.source.displays {
            output.append("## \(display.alias)")
            output.append("")
            output.append("- displayID: \(display.displayID)")
            output.append("- index: \(display.index)")
            output.append("- frameSize: \(Int(display.frameSize.width))x\(Int(display.frameSize.height))")
            output.append("")

            if display.blocks.isEmpty {
                output.append("_No OCR blocks detected._")
                output.append("")
                continue
            }

            for block in display.blocks {
                let annotation = document.annotation(for: block.alias)
                let role = annotation?.role.rawValue ?? ScreenTextStructureRole.unknown.rawValue
                let confidence = annotation.map { String(format: "%.2f", $0.confidence) } ?? "0.00"
                let bounds = formatBounds(block.normalizedBounds)

                output.append("[\(block.alias) role=\(role) confidence=\(confidence) bounds=\(bounds)]")
                output.append(block.text)
                output.append("")
            }
        }

        return output.joined(separator: "\n")
    }

    private func formatBounds(_ bounds: ScreenTextLLMBounds) -> String {
        let values = [bounds.x, bounds.y, bounds.width, bounds.height].map { value in
            String(format: "%.3f", value)
        }
        return "[\(values.joined(separator: ","))]"
    }
}
```

- [ ] **Step 2: Typecheck the prompt exporter**

Run:

```bash
xcrun swiftc \
  falsoai-lens/Pipelines/Vision/Models/ScreenTextLLMDocument.swift \
  falsoai-lens/Pipelines/Vision/Models/ScreenTextStructureAnnotation.swift \
  falsoai-lens/Pipelines/Vision/Services/ScreenTextStructuredPromptExporter.swift \
  -typecheck
```

Expected: no output and exit code `0`.

- [ ] **Step 3: Commit**

```bash
git add falsoai-lens/Pipelines/Vision/Services/ScreenTextStructuredPromptExporter.swift
git commit -m "feat: add structured screen text prompt exporter"
```

---

### Task 4: Add LLM Preparation Orchestration

**Files:**

- Create: `falsoai-lens/Pipelines/Vision/Services/ScreenTextLLMPreparationService.swift`

- [ ] **Step 1: Create preparation result and service**

Create `falsoai-lens/Pipelines/Vision/Services/ScreenTextLLMPreparationService.swift`:

```swift
import Foundation

struct ScreenTextLLMPreparation: Equatable, Sendable {
    let factualDocument: ScreenTextLLMDocument
    let structuredDocument: ScreenTextStructuredLLMDocument
    let factualMarkdown: String
    let compactJSON: String
    let chunks: [ScreenTextLLMChunk]
    let structuredMarkdown: String
}

struct ScreenTextLLMPreparationService {
    private let exporter: ScreenTextLLMExporter
    private let classifier: any ScreenTextStructureClassifying
    private let promptExporter: ScreenTextStructuredPromptExporter

    init(
        exporter: ScreenTextLLMExporter = ScreenTextLLMExporter(),
        classifier: any ScreenTextStructureClassifying = HeuristicScreenTextStructureClassifier(),
        promptExporter: ScreenTextStructuredPromptExporter = ScreenTextStructuredPromptExporter()
    ) {
        self.exporter = exporter
        self.classifier = classifier
        self.promptExporter = promptExporter
    }

    func prepare(
        _ document: MultiDisplayScreenTextDocument,
        maxChunkCharacters: Int = 6_000
    ) throws -> ScreenTextLLMPreparation {
        let factualDocument = exporter.export(document)
        let structuredDocument = classifier.classify(factualDocument)

        return ScreenTextLLMPreparation(
            factualDocument: factualDocument,
            structuredDocument: structuredDocument,
            factualMarkdown: exporter.anchoredMarkdown(from: factualDocument),
            compactJSON: try exporter.compactJSON(from: factualDocument),
            chunks: exporter.chunks(from: factualDocument, maxCharacters: maxChunkCharacters),
            structuredMarkdown: promptExporter.markdown(from: structuredDocument)
        )
    }

    func prepare(
        _ snapshot: RealtimeScreenTextSnapshot,
        maxChunkCharacters: Int = 6_000
    ) throws -> ScreenTextLLMPreparation {
        try prepare(snapshot.document, maxChunkCharacters: maxChunkCharacters)
    }
}
```

- [ ] **Step 2: Typecheck the preparation service with existing source models**

Run:

```bash
xcrun swiftc \
  falsoai-lens/Pipelines/Vision/Models/ScreenTextDocument.swift \
  falsoai-lens/Pipelines/Vision/Models/RealtimeScreenTextSnapshot.swift \
  falsoai-lens/Pipelines/Vision/Models/ScreenTextLLMDocument.swift \
  falsoai-lens/Pipelines/Vision/Models/ScreenTextStructureAnnotation.swift \
  falsoai-lens/Pipelines/Vision/Services/ScreenTextLLMExporter.swift \
  falsoai-lens/Pipelines/Vision/Services/ScreenTextStructureClassifier.swift \
  falsoai-lens/Pipelines/Vision/Services/ScreenTextStructuredPromptExporter.swift \
  falsoai-lens/Pipelines/Vision/Services/ScreenTextLLMPreparationService.swift \
  falsoai-lens/Pipelines/Vision/Services/ScreenTextHasher.swift \
  -typecheck
```

Expected: no output and exit code `0`.

- [ ] **Step 3: Commit**

```bash
git add falsoai-lens/Pipelines/Vision/Services/ScreenTextLLMPreparationService.swift
git commit -m "feat: add screen text llm preparation service"
```

---

### Task 5: Add Deterministic Smoke Checks

**Files:**

- Create: `/private/tmp/falsoai-lens-screen-text-structure-classifier-tests/main.swift`
- Uses app source files from `falsoai-lens/Pipelines/Vision/...`

- [ ] **Step 1: Create the smoke-check harness**

Create `/private/tmp/falsoai-lens-screen-text-structure-classifier-tests/main.swift`:

```swift
import CoreGraphics
import Foundation

func makeBlock(
    alias: String,
    text: String,
    x: Double = 0.1,
    y: Double = 0.1,
    width: Double = 0.3,
    height: Double = 0.05,
    readingOrder: Int = 1
) -> ScreenTextLLMBlock {
    ScreenTextLLMBlock(
        alias: alias,
        sourceID: UUID(),
        readingOrder: readingOrder,
        text: text,
        bounds: ScreenTextLLMBounds(
            x: x * 1000,
            y: y * 1000,
            width: width * 1000,
            height: height * 1000
        ),
        normalizedBounds: ScreenTextLLMBounds(
            x: x,
            y: y,
            width: width,
            height: height
        ),
        lineAliases: [],
        metrics: ScreenTextLLMMetrics(
            characterCount: text.count,
            wordCount: text.split(whereSeparator: \.isWhitespace).count,
            areaRatio: width * height
        )
    )
}

func makeDocument(blocks: [ScreenTextLLMBlock]) -> ScreenTextLLMDocument {
    ScreenTextLLMDocument(
        sourceDocumentID: UUID(),
        capturedAt: Date(timeIntervalSince1970: 1_000),
        displayCount: 1,
        observationCount: 0,
        lineCount: 0,
        blockCount: blocks.count,
        regionCount: 0,
        displays: [
            ScreenTextLLMDisplay(
                alias: "d1",
                displayID: 1,
                index: 0,
                capturedAt: Date(timeIntervalSince1970: 1_000),
                frameSize: ScreenTextLLMSize(width: 1000, height: 1000),
                frameHash: "frame",
                normalizedTextHash: "text",
                layoutHash: "layout",
                text: blocks.map(\.text).joined(separator: "\n"),
                regions: [],
                blocks: blocks,
                lines: [],
                observations: []
            )
        ]
    )
}

func expectRole(
    _ expectedRole: ScreenTextStructureRole,
    for text: String,
    x: Double = 0.1,
    y: Double = 0.1,
    width: Double = 0.3,
    height: Double = 0.05
) {
    let block = makeBlock(
        alias: "d1.b1",
        text: text,
        x: x,
        y: y,
        width: width,
        height: height
    )
    let document = makeDocument(blocks: [block])
    let structured = HeuristicScreenTextStructureClassifier().classify(document)
    let actualRole = structured.annotation(for: "d1.b1")?.role

    precondition(
        actualRole == expectedRole,
        "Expected \(text) to classify as \(expectedRole.rawValue), got \(actualRole?.rawValue ?? "nil")"
    )
}

expectRole(.buttonLike, for: "Save changes", width: 0.2, height: 0.04)
expectRole(.formLabel, for: "Email:")
expectRole(.inputPlaceholder, for: "Enter your email")
expectRole(.priceOrNumber, for: "$19.99")
expectRole(.codeOrLog, for: "ERROR request failed with status=500")
expectRole(.paragraph, for: "This is a longer paragraph of screen text that should be treated as prose-like content for an LLM preparation layer.")
expectRole(.navigation, for: "Settings", x: 0.02, y: 0.08, width: 0.12, height: 0.04)

let promptDocument = makeDocument(blocks: [
    makeBlock(alias: "d1.b1", text: "Account Settings", x: 0.1, y: 0.05, width: 0.4, height: 0.08),
    makeBlock(alias: "d1.b2", text: "Email:", x: 0.1, y: 0.2, width: 0.12, height: 0.04),
    makeBlock(alias: "d1.b3", text: "Save changes", x: 0.1, y: 0.3, width: 0.2, height: 0.04)
])
let structured = HeuristicScreenTextStructureClassifier().classify(promptDocument)
let markdown = ScreenTextStructuredPromptExporter().markdown(from: structured)

precondition(markdown.contains("[d1.b1 role=heading"), "Expected heading annotation in markdown")
precondition(markdown.contains("[d1.b2 role=formLabel"), "Expected form label annotation in markdown")
precondition(markdown.contains("[d1.b3 role=buttonLike"), "Expected button annotation in markdown")
precondition(markdown.contains("Roles are deterministic layout hints"), "Expected structure note in markdown")

print("Screen text structure classifier smoke checks passed.")
```

- [ ] **Step 2: Run the smoke-check harness**

Run:

```bash
xcrun swift \
  falsoai-lens/Pipelines/Vision/Models/ScreenTextLLMDocument.swift \
  falsoai-lens/Pipelines/Vision/Models/ScreenTextStructureAnnotation.swift \
  falsoai-lens/Pipelines/Vision/Services/ScreenTextStructureClassifier.swift \
  falsoai-lens/Pipelines/Vision/Services/ScreenTextStructuredPromptExporter.swift \
  /private/tmp/falsoai-lens-screen-text-structure-classifier-tests/main.swift
```

Expected:

```text
Screen text structure classifier smoke checks passed.
```

- [ ] **Step 3: Commit source files only**

Do not commit the `/private/tmp` harness.

Run:

```bash
git status --short
```

Expected: no source changes remain uncommitted from Tasks 1-4.

---

### Task 6: Build The App

**Files:**

- Verify all app source files.

- [ ] **Step 1: Run the standard debug build**

Run:

```bash
xcodebuild -project falsoai-lens.xcodeproj -scheme falsoai-lens -configuration Debug build
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 2: Search for accidental manipulation/risk labels**

Run:

```bash
rg -n "manipulation|risk|urgency|scarcity|authority|darkPattern|threat|fear|pressure" falsoai-lens/Pipelines/Vision
```

Expected: no matches from the new classifier files. Existing historical docs or unrelated files outside `falsoai-lens/Pipelines/Vision` are not relevant to this check.

- [ ] **Step 3: Search for accidental persistence changes**

Run:

```bash
rg -n "ScreenTextStructure|structuredMarkdown|classifierID|classifierVersion" falsoai-lens/Data falsoai-lens/Pipelines/Vision/Services/RealtimeScreenTextSampler.swift falsoai-lens/Pipelines/Vision/Services/RealtimeScreenTextPipeline.swift
```

Expected:

```text
No matches.
```

This confirms structure annotations are not persisted and the realtime sampler/cache path remains factual.

---

## Acceptance Criteria

- `ScreenTextStructureAnnotation.swift` defines structural annotation DTOs only.
- `HeuristicScreenTextStructureClassifier` classifies `ScreenTextLLMBlock` aliases only.
- Classifier labels are limited to structural roles.
- No manipulation, risk, intent, persuasion, or threat labels are introduced.
- `ScreenTextStructuredPromptExporter` emits LLM-ready markdown with alias, role, confidence, bounds, and text.
- `ScreenTextLLMPreparationService` provides the future integration point for LLM analysis.
- No GRDB migration is added.
- No structure annotation is saved to `RealtimeScreenTextCache`.
- Existing realtime snapshot caching remains factual.
- Smoke harness passes.
- `xcodebuild -project falsoai-lens.xcodeproj -scheme falsoai-lens -configuration Debug build` succeeds.

## Future Follow-Ups

- Add line-level annotations only if block-level roles are too coarse for forms or tables.
- Add app/domain-aware role tuning only if factual structure alone is insufficient for LLM prompt quality.
- Add a persisted derived annotation table only if classification becomes expensive or audit history becomes necessary.
- Add a real test target and move the `/private/tmp` smoke checks into proper Swift tests.
