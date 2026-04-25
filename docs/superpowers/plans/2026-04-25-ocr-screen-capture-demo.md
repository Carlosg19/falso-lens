# OCR Screen Capture Demo Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a demo button that captures the main display, extracts visible text with Vision OCR, and sends that text through the existing manipulation scan pipeline.

**Architecture:** Use ScreenCaptureKit's `SCScreenshotManager.captureImage` for a one-shot screenshot instead of continuous streaming. Keep OCR in `OCRService`, capture in `ScreenCaptureService`, orchestration in `DemoScanPipeline`, and UI state in `ContentView`. This produces a working proof of the screen-recording plus OCR pipeline while leaving continuous background scanning for a later feature.

**Tech Stack:** SwiftUI, ScreenCaptureKit, Vision, CoreGraphics, GRDB, UserNotifications.

---

## File Structure

- Modify `falsoai-lens/Services/ScreenCaptureService.swift`: add one-shot main-display image capture using ScreenCaptureKit.
- Modify `falsoai-lens/Services/OCRService.swift`: add a convenience method that returns joined text.
- Modify `falsoai-lens/Services/DemoScanPipeline.swift`: add capture/OCR/scan orchestration state and method.
- Modify `falsoai-lens/ContentView.swift`: add a "Capture Screen + OCR" button and OCR status/result preview.
- Verify with `xcodebuild` using full Xcode.

---

### Task 1: Add One-Shot Screen Capture

**Files:**
- Modify: `falsoai-lens/Services/ScreenCaptureService.swift`

- [ ] **Step 1: Replace the file with a capture-ready service**

```swift
import CoreGraphics
import Foundation
import ScreenCaptureKit

enum ScreenCaptureError: Error {
    case permissionDenied
    case noDisplayAvailable
    case screenshotUnavailable
}

@MainActor
final class ScreenCaptureService {
    private(set) var stream: SCStream?
    private(set) var isRunning = false

    func hasScreenRecordingPermission() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    @discardableResult
    func requestScreenRecordingPermission() -> Bool {
        CGRequestScreenCaptureAccess()
    }

    func prepareForCapture() throws {
        guard hasScreenRecordingPermission() else {
            throw ScreenCaptureError.permissionDenied
        }
    }

    func captureMainDisplayImage() async throws -> CGImage {
        try prepareForCapture()

        let content = try await SCShareableContent.current
        guard let display = content.displays.first else {
            throw ScreenCaptureError.noDisplayAvailable
        }

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let configuration = SCStreamConfiguration()
        configuration.width = display.width
        configuration.height = display.height
        configuration.showsCursor = false
        configuration.queueDepth = 3
        configuration.pixelFormat = kCVPixelFormatType_32BGRA

        return try await withCheckedThrowingContinuation { continuation in
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
    }

    func stop() async {
        guard let stream else { return }
        try? await stream.stopCapture()
        self.stream = nil
        isRunning = false
    }
}
```

- [ ] **Step 2: Build-check capture service**

Run:

```bash
DEVELOPER_DIR=/Volumes/SSD/Applications/Xcode.app/Contents/Developer xcodebuild -quiet -project falsoai-lens.xcodeproj -scheme falsoai-lens -configuration Debug build
```

Expected: build succeeds.

---

### Task 2: Add OCR Convenience API

**Files:**
- Modify: `falsoai-lens/Services/OCRService.swift`

- [ ] **Step 1: Add joined text method**

Append this method inside `OCRService`:

```swift
nonisolated func recognizeJoinedText(in image: CGImage) throws -> String {
    try recognizeText(in: image)
        .joined(separator: "\n")
        .trimmingCharacters(in: .whitespacesAndNewlines)
}
```

- [ ] **Step 2: Build-check OCR service**

Run:

```bash
DEVELOPER_DIR=/Volumes/SSD/Applications/Xcode.app/Contents/Developer xcodebuild -quiet -project falsoai-lens.xcodeproj -scheme falsoai-lens -configuration Debug build
```

Expected: build succeeds.

---

### Task 3: Orchestrate Capture, OCR, and Scan

**Files:**
- Modify: `falsoai-lens/Services/DemoScanPipeline.swift`

- [ ] **Step 1: Add published OCR state and services**

Add these properties to `DemoScanPipeline`:

```swift
@Published private(set) var lastOCRText = ""
@Published private(set) var isCapturingScreen = false
```

Add these service properties:

```swift
private let ocrService = OCRService()
private let screenCaptureService: ScreenCaptureService
```

Update the initializer signature:

```swift
init(
    storage: ScanStorage? = nil,
    notificationService: NotificationService? = nil,
    screenCaptureService: ScreenCaptureService? = nil
) {
    self.storage = storage ?? (try? ScanStorage.makeDefault())
    self.notificationService = notificationService ?? NotificationService()
    self.screenCaptureService = screenCaptureService ?? ScreenCaptureService()
    refreshRecentScans()
}
```

- [ ] **Step 2: Add capture-and-scan method**

Add this method to `DemoScanPipeline`:

```swift
func captureScreenOCRAndScan() async {
    isCapturingScreen = true
    errorMessage = nil
    defer { isCapturingScreen = false }

    do {
        let image = try await screenCaptureService.captureMainDisplayImage()
        let recognizedText = try ocrService.recognizeJoinedText(in: image)
        lastOCRText = recognizedText

        guard !recognizedText.isEmpty else {
            errorMessage = "No readable text found on the captured screen."
            return
        }

        await scan(text: recognizedText)
    } catch {
        errorMessage = error.localizedDescription
    }
}
```

- [ ] **Step 3: Build-check pipeline**

Run:

```bash
DEVELOPER_DIR=/Volumes/SSD/Applications/Xcode.app/Contents/Developer xcodebuild -quiet -project falsoai-lens.xcodeproj -scheme falsoai-lens -configuration Debug build
```

Expected: build succeeds.

---

### Task 4: Add Screen OCR Controls to the Demo UI

**Files:**
- Modify: `falsoai-lens/ContentView.swift`

- [ ] **Step 1: Add capture button next to the existing demo scan button**

Inside the first `HStack` of scan buttons, after the "Run Demo Scan" button, add:

```swift
Button {
    Task { await pipeline.captureScreenOCRAndScan() }
} label: {
    Label(
        pipeline.isCapturingScreen ? "Capturing" : "Capture Screen + OCR",
        systemImage: "text.viewfinder"
    )
}
.disabled(pipeline.isCapturingScreen || pipeline.isScanning)
```

- [ ] **Step 2: Add OCR preview below the permission buttons**

Add this block above the existing error message block:

```swift
if !pipeline.lastOCRText.isEmpty {
    VStack(alignment: .leading, spacing: 8) {
        Text("Last OCR Capture")
            .font(.headline)
        Text(pipeline.lastOCRText)
            .lineLimit(6)
            .textSelection(.enabled)
            .foregroundStyle(.secondary)
    }
    .padding()
    .background(.thinMaterial)
    .clipShape(RoundedRectangle(cornerRadius: 8))
}
```

- [ ] **Step 3: Update the support copy**

Replace:

```swift
Text("Paste visible-screen text to exercise analysis, storage, and notification services.")
```

With:

```swift
Text("Paste text or capture the main display to exercise screen recording, OCR, analysis, storage, and notifications.")
```

- [ ] **Step 4: Build-check UI**

Run:

```bash
DEVELOPER_DIR=/Volumes/SSD/Applications/Xcode.app/Contents/Developer xcodebuild -quiet -project falsoai-lens.xcodeproj -scheme falsoai-lens -configuration Debug build
```

Expected: build succeeds.

---

### Task 5: Manual Verification

**Files:**
- Verify the app through Xcode.

- [ ] **Step 1: Build**

Run:

```bash
DEVELOPER_DIR=/Volumes/SSD/Applications/Xcode.app/Contents/Developer xcodebuild -quiet -project falsoai-lens.xcodeproj -scheme falsoai-lens -configuration Debug build
```

Expected: build succeeds.

- [ ] **Step 2: Run the app**

Expected:
- The dashboard shows "Capture Screen + OCR".
- Clicking "Request Screen Recording" opens or triggers the macOS screen recording permission flow if permission is missing.
- With permission granted, clicking "Capture Screen + OCR" captures the main display.
- OCR text appears under "Last OCR Capture".
- Recognized text is analyzed and saved as a recent scan.

- [ ] **Step 3: Confirm denied-permission behavior**

Expected:
- If screen recording permission is missing, the capture button surfaces an error message instead of crashing.

---

## Self-Review

- Spec coverage: this plan adds screen recording permission-gated capture, Vision OCR extraction, UI controls, and pipeline integration.
- Scope: continuous background recording is intentionally excluded; this is a simple one-shot demo that proves the OCR and capture path.
- Type consistency: `ScreenCaptureService.captureMainDisplayImage()`, `OCRService.recognizeJoinedText(in:)`, and `DemoScanPipeline.captureScreenOCRAndScan()` are used consistently across tasks.
