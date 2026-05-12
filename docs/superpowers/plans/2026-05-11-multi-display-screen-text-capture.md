# Multi-Display Screen Text Capture Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Capture visible text from every available display, structure each display independently, and expose one aggregate screen-text result without adding inference or classification.

**Architecture:** Keep capture, OCR, document building, cache, and UI separate. `ScreenCaptureService` should return one captured image per `SCDisplay`; `ScreenTextPipeline` should OCR/build/cache each display document separately; a new aggregate model should combine those per-display documents for UI and storage-friendly flattened text. The existing `ScreenTextDocument` remains factual and geometry-local to one display.

**Tech Stack:** Swift, SwiftUI, ScreenCaptureKit, Vision OCR, CryptoKit, Swift actors, existing file-system synchronized Xcode group.

---

## Meta-Analysis

The user wants the current screen-text pipeline to include text from all monitors, not just the first display returned by ScreenCaptureKit. The root cause is `ScreenCaptureService.captureMainDisplayImage()` selecting `content.displays.first`, then creating `SCContentFilter(display:)` for only that display. The architectural pressure is that `ScreenTextDocument` currently represents one frame and one coordinate space; multi-display support should not pretend multiple displays are one image.

Affected files:
- Modify: `falsoai-lens/Pipelines/Vision/Services/ScreenCaptureService.swift`
- Modify: `falsoai-lens/Pipelines/Vision/Services/ScreenTextPipeline.swift`
- Modify: `falsoai-lens/Pipelines/Vision/Models/ScreenTextDocument.swift`
- Modify: `falsoai-lens/Pipelines/Vision/Services/ScreenTextMemory.swift`
- Modify: `falsoai-lens/Pipelines/Vision/Services/ScreenTextHasher.swift`
- Modify: `falsoai-lens/ContentView.swift`
- Temporary verification harness: `/private/tmp/falsoai-lens-screen-text-builder-tests/main.swift`

What could break:
- Coordinate assumptions if documents from different displays are merged into one coordinate space.
- Cache collisions if identical pixels on different displays use only `frameHash`.
- UI/state naming confusion if `latestDocument` continues to imply a single display.
- Capture latency if displays are processed strictly serially.
- Existing flat `ScreenTextRecord` persistence if recognized text concatenation changes unexpectedly.

Verification:
- Pure Swift harness for aggregate model and memory behavior.
- `xcodebuild -project falsoai-lens.xcodeproj -scheme falsoai-lens -configuration Debug build`.
- Manual capture with text visible on two displays and confirm both display sections appear in UI.

---

## File Structure

Use the existing `ScreenTextDocument` as the per-display document. Add aggregate types in the same model file to keep the single-display and multi-display contracts together:

```swift
struct CapturedDisplayFrame
struct MultiDisplayScreenTextDocument
struct DisplayScreenTextDocument
```

Do not add semantic roles, classifiers, risks, inference, or LLM hooks.

---

## Task 1: Add Multi-Display Model Types

**Files:**
- Modify: `falsoai-lens/Pipelines/Vision/Models/ScreenTextDocument.swift`

- [ ] **Step 1: Extend the model with display metadata and aggregate documents**

Add these factual types below `ScreenTextDigest`:

```swift
struct DisplayScreenTextDocument: Identifiable, Codable, Equatable, Sendable {
    var id: UInt32 { displayID }

    let displayID: UInt32
    let index: Int
    let document: ScreenTextDocument

    var recognizedText: String {
        document.recognizedText
    }
}

struct MultiDisplayScreenTextDocument: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    let capturedAt: Date
    let displays: [DisplayScreenTextDocument]

    var recognizedText: String {
        displays
            .filter { !$0.recognizedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .map { display in
                "Display \(display.index + 1)\n\(display.recognizedText)"
            }
            .joined(separator: "\n\n")
    }

    var observationCount: Int {
        displays.reduce(0) { $0 + $1.document.observations.count }
    }

    var lineCount: Int {
        displays.reduce(0) { $0 + $1.document.lines.count }
    }

    var blockCount: Int {
        displays.reduce(0) { $0 + $1.document.blocks.count }
    }

    var regionCount: Int {
        displays.reduce(0) { $0 + $1.document.regions.count }
    }

    init(
        id: UUID = UUID(),
        capturedAt: Date,
        displays: [DisplayScreenTextDocument]
    ) {
        self.id = id
        self.capturedAt = capturedAt
        self.displays = displays
    }
}
```

- [ ] **Step 2: Compile-check the model**

Run:

```bash
xcodebuild -project falsoai-lens.xcodeproj -scheme falsoai-lens -configuration Debug build
```

Expected: build may fail later because pipeline still expects only `ScreenTextDocument`, but it should not fail because of syntax or missing imports in the model file.

---

## Task 2: Capture Every Display

**Files:**
- Modify: `falsoai-lens/Pipelines/Vision/Services/ScreenCaptureService.swift`

- [ ] **Step 1: Add captured frame type**

Add near the top, below `ScreenCaptureError`:

```swift
struct CapturedDisplayFrame: Identifiable, Sendable {
    var id: UInt32 { displayID }

    let displayID: UInt32
    let index: Int
    let image: CGImage
}
```

- [ ] **Step 2: Extract reusable single-display capture helper**

Inside `ScreenCaptureService`, add:

```swift
private func captureImage(for display: SCDisplay, index: Int) async throws -> CapturedDisplayFrame {
    logger.info("Using display id=\(display.displayID, privacy: .public), width=\(display.width, privacy: .public), height=\(display.height, privacy: .public)")

    let filter = SCContentFilter(display: display, excludingWindows: [])
    let configuration = SCStreamConfiguration()
    configuration.width = display.width
    configuration.height = display.height
    configuration.showsCursor = false
    configuration.queueDepth = 3
    configuration.pixelFormat = kCVPixelFormatType_32BGRA

    let captureLogger = logger
    let image = try await withCheckedThrowingContinuation { continuation in
        captureLogger.info("Calling SCScreenshotManager.captureImage for display id=\(display.displayID, privacy: .public)")
        SCScreenshotManager.captureImage(
            contentFilter: filter,
            configuration: configuration
        ) { image, error in
            if let error {
                captureLogger.error("SCScreenshotManager capture failed: \(Self.errorLogDescription(for: error), privacy: .public)")
                continuation.resume(throwing: error)
                return
            }

            guard let image else {
                captureLogger.error("SCScreenshotManager returned nil image without an error")
                continuation.resume(throwing: ScreenCaptureError.screenshotUnavailable)
                return
            }

            captureLogger.info("SCScreenshotManager returned image width=\(image.width, privacy: .public), height=\(image.height, privacy: .public)")
            continuation.resume(returning: image)
        }
    }

    return CapturedDisplayFrame(
        displayID: display.displayID,
        index: index,
        image: image
    )
}
```

- [ ] **Step 3: Add all-display capture API**

Add:

```swift
func captureAllDisplayImages() async throws -> [CapturedDisplayFrame] {
    logger.info("Starting all-display screen capture")
    logger.info("Capture runtime bundle=\(Bundle.main.bundleIdentifier ?? "unknown", privacy: .public), app=\(Bundle.main.bundlePath, privacy: .public), executable=\(Bundle.main.executablePath ?? "unknown", privacy: .public)")
    try prepareForCapture()
    logger.info("Screen recording preflight permission passed")

    let content: SCShareableContent
    do {
        logger.info("Loading SCShareableContent.current")
        content = try await SCShareableContent.current
    } catch {
        logger.error("SCShareableContent.current failed: \(Self.errorLogDescription(for: error), privacy: .public)")
        throw error
    }

    logger.info("Loaded shareable content. displays=\(content.displays.count, privacy: .public), windows=\(content.windows.count, privacy: .public), applications=\(content.applications.count, privacy: .public)")
    logger.info("Shareable display IDs: \(content.displays.map { String($0.displayID) }.joined(separator: ","), privacy: .public)")

    guard !content.displays.isEmpty else {
        logger.error("No display available in shareable content")
        throw ScreenCaptureError.noDisplayAvailable
    }

    var frames: [CapturedDisplayFrame] = []
    for (index, display) in content.displays.enumerated() {
        frames.append(try await captureImage(for: display, index: index))
    }
    return frames
}
```

- [ ] **Step 4: Preserve existing single-display API**

Rewrite `captureMainDisplayImage()` as:

```swift
func captureMainDisplayImage() async throws -> CGImage {
    guard let firstFrame = try await captureAllDisplayImages().first else {
        throw ScreenCaptureError.noDisplayAvailable
    }
    return firstFrame.image
}
```

- [ ] **Step 5: Build-check capture service**

Run:

```bash
xcodebuild -project falsoai-lens.xcodeproj -scheme falsoai-lens -configuration Debug build
```

Expected: build succeeds or exposes only call-site issues in `ScreenTextPipeline`.

---

## Task 3: Make Memory Cache Display-Aware

**Files:**
- Modify: `falsoai-lens/Pipelines/Vision/Services/ScreenTextHasher.swift`
- Modify: `falsoai-lens/Pipelines/Vision/Services/ScreenTextMemory.swift`

- [ ] **Step 1: Add display-aware frame cache key**

In `ScreenTextHasher`, add:

```swift
static func displayFrameHash(displayID: UInt32, image: CGImage) -> String {
    hashString("display:\(displayID)|frame:\(hashFrame(image))")
}
```

- [ ] **Step 2: Keep `ScreenTextMemory` unchanged unless verification reveals an issue**

`ScreenTextMemory` already keys by `document.frameHash`. Because the pipeline will now pass `displayFrameHash(displayID:image:)`, identical pixels on two displays will still have different cache keys.

- [ ] **Step 3: Verify pure compile**

Run:

```bash
xcrun swiftc falsoai-lens/Pipelines/Vision/Models/ScreenTextDocument.swift falsoai-lens/Pipelines/Vision/Services/ScreenTextHasher.swift falsoai-lens/Pipelines/Vision/Services/ScreenTextMemory.swift -o /private/tmp/falsoai-lens-screen-text-memory-check
```

Expected: if sandbox blocks module-cache writes, rerun with approval. Compile succeeds.

---

## Task 4: Aggregate Multi-Display Documents in the Pipeline

**Files:**
- Modify: `falsoai-lens/Pipelines/Vision/Services/ScreenTextPipeline.swift`

- [ ] **Step 1: Change published state**

Replace:

```swift
@Published private(set) var latestDocument: ScreenTextDocument?
@Published private(set) var lastCaptureUsedCache = false
```

With:

```swift
@Published private(set) var latestDocument: MultiDisplayScreenTextDocument?
@Published private(set) var lastCaptureUsedCache = false
@Published private(set) var lastCapturedDisplayCount = 0
```

- [ ] **Step 2: Replace single-image capture flow**

In `captureScreenText()`, replace the single `captureMainDisplayImage()` section with:

```swift
let frames = try await screenCaptureService.captureAllDisplayImages()
let capturedAt = Date()
lastCapturedDisplayCount = frames.count
captureStatus = "Captured \(frames.count) display\(frames.count == 1 ? "" : "s"). Checking cache."

var displayDocuments: [DisplayScreenTextDocument] = []
var reusedCacheCount = 0

for frame in frames {
    let frameHash = ScreenTextHasher.displayFrameHash(
        displayID: frame.displayID,
        image: frame.image
    )

    if let cachedDocument = await memory.cachedDocument(forFrameHash: frameHash) {
        reusedCacheCount += 1
        displayDocuments.append(
            DisplayScreenTextDocument(
                displayID: frame.displayID,
                index: frame.index,
                document: cachedDocument
            )
        )
        continue
    }

    captureStatus = "Running OCR for display \(frame.index + 1) of \(frames.count)."
    let observations = try ocrService.recognizeTextObservations(in: frame.image)
    let document = documentBuilder.build(
        observations: observations,
        frameSize: CGSize(width: CGFloat(frame.image.width), height: CGFloat(frame.image.height)),
        frameHash: frameHash,
        capturedAt: capturedAt
    )
    let storedDocument = await memory.store(document)
    displayDocuments.append(
        DisplayScreenTextDocument(
            displayID: frame.displayID,
            index: frame.index,
            document: storedDocument
        )
    )
}

let aggregateDocument = MultiDisplayScreenTextDocument(
    capturedAt: capturedAt,
    displays: displayDocuments.sorted { $0.index < $1.index }
)
latestDocument = aggregateDocument
lastCaptureUsedCache = reusedCacheCount == frames.count

let recognizedText = aggregateDocument.recognizedText.trimmingCharacters(in: .whitespacesAndNewlines)
lastOCRText = recognizedText
```

- [ ] **Step 3: Keep save behavior flat**

Keep the existing `saveText(recognizedText, source: "Main Display")` call, but change the source string:

```swift
let source = frames.count == 1 ? "Display 1" : "All Displays"
let savedRecord = try saveText(recognizedText, source: source)
```

- [ ] **Step 4: Update status and log counts**

Use aggregate counts:

```swift
captureStatus = "Screen text captured from \(frames.count) display\(frames.count == 1 ? "" : "s"), structured, cached, and saved."
logger.info("Screen text capture completed displays=\(aggregateDocument.displays.count, privacy: .public), characters=\(recognizedText.count, privacy: .public), observations=\(aggregateDocument.observationCount, privacy: .public), lines=\(aggregateDocument.lineCount, privacy: .public), blocks=\(aggregateDocument.blockCount, privacy: .public), regions=\(aggregateDocument.regionCount, privacy: .public), cachedDisplays=\(reusedCacheCount, privacy: .public)")
```

- [ ] **Step 5: Build-check pipeline**

Run:

```bash
xcodebuild -project falsoai-lens.xcodeproj -scheme falsoai-lens -configuration Debug build
```

Expected: if build fails, remaining failures should be UI references to `latestDocument` counts.

---

## Task 5: Update UI Counts for Multi-Display

**Files:**
- Modify: `falsoai-lens/ContentView.swift`

- [ ] **Step 1: Update summary labels**

In the existing `if let document = screenText.latestDocument` block, replace per-document counts with aggregate counts:

```swift
HStack(spacing: 12) {
    Label("\(document.displays.count) displays", systemImage: "display.2")
    Label("\(document.observationCount) observations", systemImage: "text.magnifyingglass")
    Label("\(document.lineCount) lines", systemImage: "text.line.first.and.arrowtriangle.forward")
    Label("\(document.blockCount) blocks", systemImage: "text.alignleft")
    Label("\(document.regionCount) regions", systemImage: "rectangle.3.group")
    Label(screenText.lastCaptureUsedCache ? "Memory cache" : "Fresh OCR", systemImage: screenText.lastCaptureUsedCache ? "memorychip" : "camera.viewfinder")
}
```

- [ ] **Step 2: Replace frame-size line with per-display sizes**

Replace:

```swift
Text("Frame \(Int(document.frameSize.width)) x \(Int(document.frameSize.height)) | captured \(document.capturedAt.formatted(date: .omitted, time: .standard))")
```

With:

```swift
Text(
    document.displays
        .map { display in
            "Display \(display.index + 1): \(Int(display.document.frameSize.width)) x \(Int(display.document.frameSize.height))"
        }
        .joined(separator: " | ")
    + " | captured \(document.capturedAt.formatted(date: .omitted, time: .standard))"
)
```

- [ ] **Step 3: Build-check UI**

Run:

```bash
xcodebuild -project falsoai-lens.xcodeproj -scheme falsoai-lens -configuration Debug build
```

Expected: build succeeds.

---

## Task 6: Verification Harness and Manual Check

**Files:**
- Modify temporary harness only: `/private/tmp/falsoai-lens-screen-text-builder-tests/main.swift`

- [ ] **Step 1: Add aggregate model checks to the temporary harness**

Append:

```swift
let secondDocument = builder.build(
    observations: [
        ScreenTextObservation(
            text: "Other display",
            boundingBox: CGRect(x: 20, y: 20, width: 80, height: 16),
            confidence: 0.95
        )
    ],
    frameSize: CGSize(width: 300, height: 200),
    frameHash: "display-2-frame",
    capturedAt: Date()
)

let aggregate = MultiDisplayScreenTextDocument(
    capturedAt: Date(),
    displays: [
        DisplayScreenTextDocument(displayID: 10, index: 0, document: document),
        DisplayScreenTextDocument(displayID: 20, index: 1, document: secondDocument)
    ]
)

expect(aggregate.displays.count == 2, "aggregate should keep both displays")
expect(aggregate.recognizedText.contains("Display 1"), "aggregate text should label first display")
expect(aggregate.recognizedText.contains("Display 2"), "aggregate text should label second display")
expect(aggregate.observationCount == document.observations.count + secondDocument.observations.count, "aggregate should sum observations")
```

- [ ] **Step 2: Run harness**

Run:

```bash
xcrun swiftc falsoai-lens/Pipelines/Vision/Models/ScreenTextDocument.swift falsoai-lens/Pipelines/Vision/Services/ScreenTextHasher.swift falsoai-lens/Pipelines/Vision/Services/ScreenTextDocumentBuilder.swift falsoai-lens/Pipelines/Vision/Services/ScreenTextMemory.swift /private/tmp/falsoai-lens-screen-text-builder-tests/main.swift -o /private/tmp/falsoai-lens-screen-text-builder-tests/check
/private/tmp/falsoai-lens-screen-text-builder-tests/check
```

Expected:

```text
Screen text builder checks passed
```

- [ ] **Step 3: Run full build**

Run:

```bash
xcodebuild -project falsoai-lens.xcodeproj -scheme falsoai-lens -configuration Debug build
```

Expected:

```text
** BUILD SUCCEEDED **
```

- [ ] **Step 4: Manual multi-display validation**

Manual setup:
- Put visible, distinct text on display 1, for example `DISPLAY ONE TEXT`.
- Put visible, distinct text on display 2, for example `DISPLAY TWO TEXT`.
- Click `Capture Screen Text`.

Expected UI:
- Summary says `2 displays`.
- OCR text contains both display labels.
- OCR text contains both `DISPLAY ONE TEXT` and `DISPLAY TWO TEXT`.
- Repeating capture without changing displays reports memory cache or cached display reuse.

---

## Self-Review

Spec coverage:
- Captures all monitors by iterating `SCShareableContent.current.displays`.
- Keeps one factual `ScreenTextDocument` per display.
- Adds aggregate document only for UI and flat text output.
- Keeps cache display-aware via display ID in frame hash.
- Adds no classification, inference, LLM, risk score, or semantic role.

Placeholder scan:
- No unfinished markers remain.
- Each task lists exact files, code snippets, and verification commands.

Type consistency:
- `DisplayScreenTextDocument.document` is a `ScreenTextDocument`.
- `MultiDisplayScreenTextDocument` exposes the aggregate count properties used by `ContentView`.
- `ScreenTextPipeline.latestDocument` changes from `ScreenTextDocument?` to `MultiDisplayScreenTextDocument?`.
