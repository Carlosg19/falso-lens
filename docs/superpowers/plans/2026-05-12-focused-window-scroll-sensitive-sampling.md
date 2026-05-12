# Focused Window Scroll-Sensitive Sampling Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Improve scroll-text detection by sampling only the focused window at a faster interval, defaulting to 1 second, while falling back to all-display capture when focused-window capture is unavailable.

**Architecture:** Keep the current realtime cache, OCR, hashing, and duplicate-skip behavior. Add a focused-window metadata resolver based on Accessibility, a focused-window ScreenCaptureKit capture path, and a sampler mode that prefers the focused window. The realtime loop remains periodic because scrolling inside a view does not reliably emit macOS window events.

**Tech Stack:** Swift, AppKit, ApplicationServices Accessibility, ScreenCaptureKit, Vision OCR, GRDB, SwiftUI, Swift concurrency.

---

## Why This Plan

The user wants better detection when text changes because they scroll inside a view. Event-only capture is not enough because many apps do not emit a notification for every scroll repaint. A faster periodic sampler remains the right foundation, but sampling the focused window instead of all displays reduces work enough to make a 0.75-1.0 second interval reasonable.

This plan targets:

- default interval: 1 second,
- primary capture target: focused window,
- fallback target: all displays,
- cache writes: unchanged from today, only when readable text exists and text/layout changed.

## File Structure

- Create `falsoai-lens/Pipelines/Vision/Models/FocusedWindowCaptureTarget.swift`
  - Stores focused app/window metadata used to match an `SCWindow`.

- Create `falsoai-lens/Pipelines/Vision/Services/FocusedWindowResolver.swift`
  - Uses `NSWorkspace.shared.frontmostApplication` and Accessibility focused-window attributes.
  - Returns a focused app PID, app name, optional window title, and optional bounds.

- Modify `falsoai-lens/Pipelines/Vision/Services/ScreenCaptureService.swift`
  - Add `CapturedWindowFrame`.
  - Add focused-window capture by matching resolver metadata to `SCShareableContent.current.windows`.
  - Keep existing all-display capture unchanged.

- Modify `falsoai-lens/Pipelines/Vision/Services/ScreenTextHasher.swift`
  - Add `windowFrameHash(windowID:image:)`.

- Modify `falsoai-lens/Pipelines/Vision/Models/RealtimeScreenTextSnapshot.swift`
  - Add capture target metadata so UI can show whether focused window or all displays were used.

- Modify `falsoai-lens/Data/ScreenTextCache/Records/RealtimeScreenTextSnapshotRecord.swift`
  - Persist capture target metadata.

- Modify `falsoai-lens/Data/ScreenTextCache/RealtimeScreenTextCacheMigrations.swift`
  - Add migration for capture target metadata.

- Modify `falsoai-lens/Data/ScreenTextCache/RealtimeScreenTextCache.swift`
  - Save the new metadata.

- Modify `falsoai-lens/Pipelines/Vision/Services/RealtimeScreenTextSampler.swift`
  - Prefer focused-window capture.
  - Fall back to all-display capture if focused-window metadata or window capture fails.

- Modify `falsoai-lens/Pipelines/Vision/Services/RealtimeScreenTextPipeline.swift`
  - Lower default sampling interval from 2 seconds to 1 second.
  - Allow 0.75 second minimum if future UI/settings pass it in.
  - Update status text with capture target.

- Modify `falsoai-lens/ContentView.swift`
  - Display focused-window vs all-display mode in realtime controls and cached text section.

---

### Task 1: Add Focused Window Target Model

**Files:**

- Create: `falsoai-lens/Pipelines/Vision/Models/FocusedWindowCaptureTarget.swift`

- [ ] **Step 1: Write the target model**

Create:

```swift
import CoreGraphics
import Foundation

enum ScreenTextCaptureTargetKind: String, Codable, Equatable, Sendable {
    case focusedWindow
    case allDisplays
}

struct FocusedWindowCaptureTarget: Equatable, Sendable {
    let processID: pid_t
    let applicationName: String
    let windowTitle: String?
    let windowBounds: CGRect?

    init(
        processID: pid_t,
        applicationName: String,
        windowTitle: String? = nil,
        windowBounds: CGRect? = nil
    ) {
        self.processID = processID
        self.applicationName = applicationName
        self.windowTitle = windowTitle
        self.windowBounds = windowBounds
    }
}
```

- [ ] **Step 2: Typecheck**

Run:

```bash
xcrun swiftc falsoai-lens/Pipelines/Vision/Models/FocusedWindowCaptureTarget.swift -typecheck
```

Expected: no output and exit code 0.

---

### Task 2: Add Focused Window Resolver

**Files:**

- Create: `falsoai-lens/Pipelines/Vision/Services/FocusedWindowResolver.swift`

- [ ] **Step 1: Create resolver**

Create:

```swift
import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

@MainActor
struct FocusedWindowResolver {
    func resolveFocusedWindow() -> FocusedWindowCaptureTarget? {
        guard let app = NSWorkspace.shared.frontmostApplication else {
            return nil
        }

        let processID = app.processIdentifier
        let applicationName = app.localizedName ?? app.bundleIdentifier ?? "Unknown App"

        guard AXIsProcessTrusted() else {
            return FocusedWindowCaptureTarget(
                processID: processID,
                applicationName: applicationName
            )
        }

        let appElement = AXUIElementCreateApplication(processID)
        var focusedWindowValue: CFTypeRef?
        let focusedWindowStatus = AXUIElementCopyAttributeValue(
            appElement,
            kAXFocusedWindowAttribute as CFString,
            &focusedWindowValue
        )

        guard focusedWindowStatus == .success,
              let focusedWindowValue else {
            return FocusedWindowCaptureTarget(
                processID: processID,
                applicationName: applicationName
            )
        }

        let windowElement = focusedWindowValue as! AXUIElement
        return FocusedWindowCaptureTarget(
            processID: processID,
            applicationName: applicationName,
            windowTitle: windowTitle(for: windowElement),
            windowBounds: windowBounds(for: windowElement)
        )
    }

    private func windowTitle(for windowElement: AXUIElement) -> String? {
        var titleValue: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(
            windowElement,
            kAXTitleAttribute as CFString,
            &titleValue
        )

        guard status == .success else { return nil }
        return titleValue as? String
    }

    private func windowBounds(for windowElement: AXUIElement) -> CGRect? {
        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?

        let positionStatus = AXUIElementCopyAttributeValue(
            windowElement,
            kAXPositionAttribute as CFString,
            &positionValue
        )
        let sizeStatus = AXUIElementCopyAttributeValue(
            windowElement,
            kAXSizeAttribute as CFString,
            &sizeValue
        )

        guard positionStatus == .success,
              sizeStatus == .success,
              let positionValue,
              let sizeValue else {
            return nil
        }

        var point = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue as! AXValue, .cgPoint, &point),
              AXValueGetValue(sizeValue as! AXValue, .cgSize, &size) else {
            return nil
        }

        return CGRect(origin: point, size: size)
    }
}
```

- [ ] **Step 2: Typecheck**

Run:

```bash
xcrun swiftc \
  falsoai-lens/Pipelines/Vision/Models/FocusedWindowCaptureTarget.swift \
  falsoai-lens/Pipelines/Vision/Services/FocusedWindowResolver.swift \
  -typecheck
```

Expected: no output and exit code 0.

---

### Task 3: Add Focused Window Capture To ScreenCaptureService

**Files:**

- Modify: `falsoai-lens/Pipelines/Vision/Services/ScreenCaptureService.swift`

- [ ] **Step 1: Add captured window frame model**

Below `CapturedDisplayFrame`, add:

```swift
struct CapturedWindowFrame: Identifiable {
    var id: UInt32 { windowID }

    let windowID: UInt32
    let processID: pid_t
    let applicationName: String
    let windowTitle: String?
    let frame: CGRect
    let image: CGImage
}
```

- [ ] **Step 2: Add focused-window capture method**

Inside `ScreenCaptureService`, below `captureMainDisplayImage()`, add:

```swift
func captureFocusedWindowImage(target: FocusedWindowCaptureTarget) async throws -> CapturedWindowFrame {
    try prepareForCapture()
    let content = try await SCShareableContent.current

    guard let window = bestMatchingWindow(in: content.windows, target: target) else {
        throw ScreenCaptureError.noDisplayAvailable
    }

    return try await captureImage(for: window, target: target)
}
```

- [ ] **Step 3: Add window matching**

Inside `ScreenCaptureService`, add:

```swift
private func bestMatchingWindow(
    in windows: [SCWindow],
    target: FocusedWindowCaptureTarget
) -> SCWindow? {
    let appWindows = windows.filter { window in
        window.owningApplication?.processID == target.processID
    }

    if let title = target.windowTitle?.trimmingCharacters(in: .whitespacesAndNewlines),
       !title.isEmpty,
       let titleMatch = appWindows.first(where: { window in
           let windowTitle = window.title.trimmingCharacters(in: .whitespacesAndNewlines)
           return !windowTitle.isEmpty
               && (windowTitle.localizedCaseInsensitiveContains(title)
                   || title.localizedCaseInsensitiveContains(windowTitle))
       }) {
        return titleMatch
    }

    if let bounds = target.windowBounds {
        return appWindows.min { lhs, rhs in
            let lhsDistance = abs(lhs.frame.midX - bounds.midX) + abs(lhs.frame.midY - bounds.midY)
            let rhsDistance = abs(rhs.frame.midX - bounds.midX) + abs(rhs.frame.midY - bounds.midY)
            return lhsDistance < rhsDistance
        }
    }

    return appWindows.first
}
```

- [ ] **Step 4: Add window image capture**

Inside `ScreenCaptureService`, add:

```swift
private func captureImage(
    for window: SCWindow,
    target: FocusedWindowCaptureTarget
) async throws -> CapturedWindowFrame {
    let filter = SCContentFilter(desktopIndependentWindow: window)
    let configuration = SCStreamConfiguration()
    configuration.width = max(1, Int(window.frame.width.rounded(.up)))
    configuration.height = max(1, Int(window.frame.height.rounded(.up)))
    configuration.showsCursor = false
    configuration.queueDepth = 3
    configuration.pixelFormat = kCVPixelFormatType_32BGRA

    let image: CGImage = try await withCheckedThrowingContinuation { continuation in
        SCScreenshotManager.captureImage(
            contentFilter: filter,
            configuration: configuration
        ) { image, error in
            if let error {
                continuation.resume(throwing: error)
                return
            }

            guard let image else {
                continuation.resume(throwing: ScreenCaptureError.screenshotUnavailable)
                return
            }

            continuation.resume(returning: image)
        }
    }

    return CapturedWindowFrame(
        windowID: window.windowID,
        processID: target.processID,
        applicationName: target.applicationName,
        windowTitle: window.title.isEmpty ? target.windowTitle : window.title,
        frame: window.frame,
        image: image
    )
}
```

- [ ] **Step 5: Build**

Run:

```bash
xcodebuild -project falsoai-lens.xcodeproj -scheme falsoai-lens -configuration Debug build
```

Expected: `** BUILD SUCCEEDED **`.

If the local SDK reports a different `SCWindow` API name, adjust only the accessor named in the compiler diagnostic.

---

### Task 4: Add Window Hashing

**Files:**

- Modify: `falsoai-lens/Pipelines/Vision/Services/ScreenTextHasher.swift`

- [ ] **Step 1: Add window frame hash**

Inside `ScreenTextHasher`, below `displayFrameHash(displayID:image:)`, add:

```swift
static func windowFrameHash(windowID: UInt32, image: CGImage) -> String {
    hashString("window:\(windowID)|frame:\(hashFrame(image))")
}
```

- [ ] **Step 2: Typecheck**

Run:

```bash
xcrun swiftc \
  falsoai-lens/Pipelines/Vision/Models/ScreenTextDocument.swift \
  falsoai-lens/Pipelines/Vision/Services/ScreenTextHasher.swift \
  -typecheck
```

Expected: no output and exit code 0.

---

### Task 5: Add Capture Target Metadata To Snapshot Cache

**Files:**

- Modify: `falsoai-lens/Pipelines/Vision/Models/RealtimeScreenTextSnapshot.swift`
- Modify: `falsoai-lens/Data/ScreenTextCache/Records/RealtimeScreenTextSnapshotRecord.swift`
- Modify: `falsoai-lens/Data/ScreenTextCache/RealtimeScreenTextCacheMigrations.swift`
- Modify: `falsoai-lens/Data/ScreenTextCache/RealtimeScreenTextCache.swift`

- [ ] **Step 1: Add snapshot fields**

Add to `RealtimeScreenTextSnapshot`:

```swift
let captureTargetKind: ScreenTextCaptureTargetKind
let captureApplicationName: String?
let captureProcessID: pid_t?
let captureWindowTitle: String?
```

- [ ] **Step 2: Add record fields**

Add to `RealtimeScreenTextSnapshotRecord`:

```swift
var captureTargetKind: String
var captureApplicationName: String?
var captureProcessID: Int32?
var captureWindowTitle: String?
```

- [ ] **Step 3: Add migration**

In `RealtimeScreenTextCacheMigrations.migrator`, after the existing create-table migration, add:

```swift
migrator.registerMigration("addRealtimeScreenTextCaptureTargetMetadata") { db in
    try db.alter(table: RealtimeScreenTextSnapshotRecord.databaseTableName) { table in
        table.add(column: "captureTargetKind", .text)
            .notNull()
            .defaults(to: ScreenTextCaptureTargetKind.allDisplays.rawValue)
        table.add(column: "captureApplicationName", .text)
        table.add(column: "captureProcessID", .integer)
        table.add(column: "captureWindowTitle", .text)
    }
}
```

- [ ] **Step 4: Save metadata**

In `RealtimeScreenTextCache.save(_:)`, add arguments to `RealtimeScreenTextSnapshotRecord(...)`:

```swift
captureTargetKind: snapshot.captureTargetKind.rawValue,
captureApplicationName: snapshot.captureApplicationName,
captureProcessID: snapshot.captureProcessID,
captureWindowTitle: snapshot.captureWindowTitle,
```

- [ ] **Step 5: Build**

Run:

```bash
xcodebuild -project falsoai-lens.xcodeproj -scheme falsoai-lens -configuration Debug build
```

Expected: `** BUILD SUCCEEDED **`.

---

### Task 6: Prefer Focused Window In Realtime Sampler

**Files:**

- Modify: `falsoai-lens/Pipelines/Vision/Services/RealtimeScreenTextSampler.swift`

- [ ] **Step 1: Add resolver property**

Add:

```swift
private let focusedWindowResolver: FocusedWindowResolver
```

Update initializer:

```swift
focusedWindowResolver: FocusedWindowResolver? = nil
```

and assign:

```swift
self.focusedWindowResolver = focusedWindowResolver ?? FocusedWindowResolver()
```

- [ ] **Step 2: Replace sample body with target preference**

Replace `sample(sessionID:sequenceNumber:)` with:

```swift
func sample(sessionID: UUID, sequenceNumber: Int) async throws -> RealtimeScreenTextSnapshot {
    if let target = focusedWindowResolver.resolveFocusedWindow() {
        do {
            return try await sampleFocusedWindow(
                sessionID: sessionID,
                sequenceNumber: sequenceNumber,
                target: target
            )
        } catch {
            logger.error("Focused-window capture failed; falling back to all displays: \(String(describing: error), privacy: .public)")
        }
    }

    return try await sampleAllDisplays(
        sessionID: sessionID,
        sequenceNumber: sequenceNumber
    )
}
```

- [ ] **Step 3: Extract existing all-display implementation**

Move the current `sample(sessionID:sequenceNumber:)` implementation into:

```swift
private func sampleAllDisplays(
    sessionID: UUID,
    sequenceNumber: Int
) async throws -> RealtimeScreenTextSnapshot
```

When constructing the snapshot, set:

```swift
captureTargetKind: .allDisplays,
captureApplicationName: nil,
captureProcessID: nil,
captureWindowTitle: nil,
```

- [ ] **Step 4: Add focused-window sample implementation**

Add:

```swift
private func sampleFocusedWindow(
    sessionID: UUID,
    sequenceNumber: Int,
    target: FocusedWindowCaptureTarget
) async throws -> RealtimeScreenTextSnapshot {
    let started = Date()
    let frame = try await screenCaptureService.captureFocusedWindowImage(target: target)
    let capturedAt = Date()
    let frameHash = ScreenTextHasher.windowFrameHash(
        windowID: frame.windowID,
        image: frame.image
    )
    let memory = memory(forDisplayID: frame.windowID)

    let document: ScreenTextDocument
    var reusedDisplayCount = 0
    var ocrDisplayCount = 0

    if let cachedDocument = await memory.cachedDocument(forFrameHash: frameHash) {
        document = cachedDocument
        reusedDisplayCount = 1
    } else {
        let observations = try ocrService.recognizeTextObservations(in: frame.image)
        let builtDocument = documentBuilder.build(
            observations: observations,
            frameSize: CGSize(width: CGFloat(frame.image.width), height: CGFloat(frame.image.height)),
            frameHash: frameHash,
            capturedAt: capturedAt
        )
        document = await memory.store(builtDocument)
        ocrDisplayCount = 1
    }

    let aggregateDocument = MultiDisplayScreenTextDocument(
        capturedAt: capturedAt,
        displays: [
            DisplayScreenTextDocument(
                displayID: frame.windowID,
                index: 0,
                document: document
            )
        ]
    )

    return try makeSnapshot(
        sessionID: sessionID,
        sequenceNumber: sequenceNumber,
        capturedAt: capturedAt,
        document: aggregateDocument,
        displayFrameHashes: [frameHash],
        reusedDisplayCount: reusedDisplayCount,
        ocrDisplayCount: ocrDisplayCount,
        elapsedSeconds: Date().timeIntervalSince(started),
        captureTargetKind: .focusedWindow,
        captureApplicationName: frame.applicationName,
        captureProcessID: frame.processID,
        captureWindowTitle: frame.windowTitle
    )
}
```

- [ ] **Step 5: Add shared snapshot factory**

Add:

```swift
private func makeSnapshot(
    sessionID: UUID,
    sequenceNumber: Int,
    capturedAt: Date,
    document: MultiDisplayScreenTextDocument,
    displayFrameHashes: [String],
    reusedDisplayCount: Int,
    ocrDisplayCount: Int,
    elapsedSeconds: Double,
    captureTargetKind: ScreenTextCaptureTargetKind,
    captureApplicationName: String?,
    captureProcessID: pid_t?,
    captureWindowTitle: String?
) throws -> RealtimeScreenTextSnapshot {
    let exportedDocument = exporter.export(document)
    let markdown = exporter.anchoredMarkdown(from: exportedDocument)
    let compactJSON = try exporter.compactJSON(from: exportedDocument)
    let chunks = exporter.chunks(from: exportedDocument)
    let recognizedText = document.recognizedText.trimmingCharacters(in: .whitespacesAndNewlines)

    return RealtimeScreenTextSnapshot(
        sessionID: sessionID,
        sequenceNumber: sequenceNumber,
        capturedAt: capturedAt,
        document: document,
        recognizedText: recognizedText,
        markdownExport: markdown,
        compactJSONExport: compactJSON,
        chunkCount: chunks.count,
        displayCount: document.displays.count,
        observationCount: document.observationCount,
        lineCount: document.lineCount,
        blockCount: document.blockCount,
        regionCount: document.regionCount,
        aggregateTextHash: ScreenTextHasher.hashAggregateText(document),
        aggregateLayoutHash: ScreenTextHasher.hashAggregateLayout(document),
        displayFrameHashes: displayFrameHashes,
        reusedDisplayCount: reusedDisplayCount,
        ocrDisplayCount: ocrDisplayCount,
        elapsedSeconds: elapsedSeconds,
        captureTargetKind: captureTargetKind,
        captureApplicationName: captureApplicationName,
        captureProcessID: captureProcessID,
        captureWindowTitle: captureWindowTitle
    )
}
```

- [ ] **Step 6: Build**

Run:

```bash
xcodebuild -project falsoai-lens.xcodeproj -scheme falsoai-lens -configuration Debug build
```

Expected: `** BUILD SUCCEEDED **`.

---

### Task 7: Lower Realtime Interval And Update Status

**Files:**

- Modify: `falsoai-lens/Pipelines/Vision/Services/RealtimeScreenTextPipeline.swift`

- [ ] **Step 1: Lower default interval**

Change initializer default:

```swift
sampleIntervalSeconds: TimeInterval = 1
```

Change assignment:

```swift
self.sampleIntervalSeconds = max(0.75, sampleIntervalSeconds)
```

- [ ] **Step 2: Update cache status**

After saving a snapshot, replace status with:

```swift
let targetLabel = snapshot.captureTargetKind == .focusedWindow ? "focused window" : "all displays"
statusText = "Cached \(targetLabel) sample \(sequenceNumber) with \(snapshot.recognizedText.count) characters."
```

- [ ] **Step 3: Build**

Run:

```bash
xcodebuild -project falsoai-lens.xcodeproj -scheme falsoai-lens -configuration Debug build
```

Expected: `** BUILD SUCCEEDED **`.

---

### Task 8: Show Focused-Window Metadata In ContentView

**Files:**

- Modify: `falsoai-lens/ContentView.swift`

- [ ] **Step 1: Add live metadata line**

In `realtimeScreenTextPanel`, inside the `if let latestSnapshot` block, add:

```swift
Text([
    latestSnapshot.captureTargetKind.rawValue,
    latestSnapshot.captureApplicationName,
    latestSnapshot.captureWindowTitle
].compactMap { $0 }.joined(separator: " | "))
    .font(.caption)
    .foregroundStyle(.secondary)
    .textSelection(.enabled)
```

- [ ] **Step 2: Add cached text metadata**

In `realtimeCachedTextSection`, inside `if let cachedSnapshot`, add:

```swift
Text([
    cachedSnapshot.captureTargetKind,
    cachedSnapshot.captureApplicationName,
    cachedSnapshot.captureWindowTitle
].compactMap { $0 }.joined(separator: " | "))
    .font(.caption)
    .foregroundStyle(.secondary)
    .textSelection(.enabled)
```

- [ ] **Step 3: Build**

Run:

```bash
xcodebuild -project falsoai-lens.xcodeproj -scheme falsoai-lens -configuration Debug build
```

Expected: `** BUILD SUCCEEDED **`.

---

### Task 9: Manual Verification For Scroll Sensitivity

**Files:**

- No code files.

- [ ] **Step 1: Launch the app**

Open the app from Xcode or the built Debug app.

- [ ] **Step 2: Verify permissions**

Verify:

- Screen Recording is authorized.
- Accessibility is authorized if you want accurate focused-window metadata.

If Accessibility is not authorized, focused-window matching may only have app PID/name and may fall back to all-display capture more often.

- [ ] **Step 3: Start realtime recording**

Click `Start`.

Expected:

- `Realtime Screen Text` shows recording.
- Samples run about once per second plus capture/OCR time.

- [ ] **Step 4: Focus a text-heavy window**

Open a browser page, Notes document, or PDF with visible text.

Expected:

- Latest sample metadata says `focusedWindow`.
- Cached text reflects the focused window text.

- [ ] **Step 5: Scroll**

Scroll down within the focused text view.

Expected:

- Within roughly 1-2 seconds, a sample sees changed visible text.
- If recognized text or layout changed, the cache updates.
- If OCR output is unchanged despite the scroll, duplicate skipping prevents a cache write.

- [ ] **Step 6: Confirm reduced all-display use**

Watch the UI metadata.

Expected:

- Most samples say `focusedWindow`.
- `allDisplays` appears only when focused-window resolution or capture fails.

---

## Expected Behavior After This Plan

- The recorder keeps periodic sampling because scrolling text does not reliably emit window events.
- The periodic target becomes the focused window instead of all displays.
- The default interval becomes 1 second.
- Duplicate skipping still prevents cache spam.
- All-display capture remains as a fallback, not the primary path.
- Cache still clears only when `Clear Cache` is clicked.

## Self-Review

Spec coverage:

- Scroll-sensitive detection is handled by faster periodic sampling.
- Workload reduction is handled by focused-window capture.
- Fallback behavior is included.
- UI explains whether focused-window or all-display capture was used.

Placeholder scan:

- No placeholder or vague implementation steps are present.

Type consistency:

- `FocusedWindowCaptureTarget` is produced by `FocusedWindowResolver`.
- `ScreenCaptureService.captureFocusedWindowImage(target:)` consumes `FocusedWindowCaptureTarget`.
- `RealtimeScreenTextSampler` stores capture metadata in `RealtimeScreenTextSnapshot`.
- `RealtimeScreenTextCache` persists snapshot capture metadata in `RealtimeScreenTextSnapshotRecord`.
