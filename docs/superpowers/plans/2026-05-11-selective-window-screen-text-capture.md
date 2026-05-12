# Selective Window Screen Text Capture Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the realtime recorder's blind all-display 2-second loop with an event-driven active-window capture path that records changed screen text when the focused app/window changes, while keeping a slower fallback heartbeat for text changes macOS does not announce.

**Architecture:** Add a new trigger layer that observes `NSWorkspace` active-application changes and Accessibility focused-window/window-geometry notifications. Add a focused-window capture path to `ScreenCaptureService` using ScreenCaptureKit `SCWindow` capture when the active window can be matched; fall back to existing all-display capture when a focused window cannot be resolved. Keep OCR, document building, hashing, LLM export, and persistent cache behavior in `RealtimeScreenTextSampler`/`RealtimeScreenTextPipeline`.

**Tech Stack:** Swift, SwiftUI, AppKit `NSWorkspace`, ApplicationServices Accessibility (`AXObserver`, `AXUIElement`), ScreenCaptureKit, Vision OCR, GRDB, Swift concurrency.

---

## Scope And Caveat

This is implementable, but not as a perfect "any pixel/text changed anywhere" event system. macOS reliably exposes events for:

- active app changes,
- focused window changes,
- many window move/resize/title changes,
- app launch/terminate notifications.

macOS does not reliably emit Accessibility notifications for every text repaint inside arbitrary apps, browser tabs, videos, canvases, or custom-rendered UI. For that reason, the implementation should be:

- event-driven for app/window changes,
- debounced so bursts of events produce one capture,
- backed by a slower focused-window heartbeat, defaulting to 10 seconds,
- able to fall back to the current all-display capture path.

## File Structure

- Create `falsoai-lens/Pipelines/Vision/Models/ScreenTextCaptureTrigger.swift`
  - Defines trigger reasons such as active app changed, focused window changed, window moved, window resized, window title changed, fallback heartbeat, manual sample.
  - Defines `ScreenTextCaptureTarget` for focused window vs all displays.

- Create `falsoai-lens/Pipelines/Vision/Services/FocusedWindowObserver.swift`
  - Owns `NSWorkspace` and Accessibility observers.
  - Publishes debounced `AsyncStream<ScreenTextCaptureTrigger>` events.
  - Tracks active app PID, app name, focused window title, and approximate bounds when available.

- Modify `falsoai-lens/Pipelines/Vision/Services/ScreenCaptureService.swift`
  - Add `CapturedWindowFrame`.
  - Add `captureFocusedWindowImage(for trigger:)`.
  - Add `captureWindowImage(window:)`.
  - Add matching from active PID/window metadata to `SCShareableContent.current.windows`.

- Modify `falsoai-lens/Pipelines/Vision/Models/RealtimeScreenTextSnapshot.swift`
  - Add trigger metadata: reason, target kind, app name, process ID, window title.

- Modify `falsoai-lens/Data/ScreenTextCache/Records/RealtimeScreenTextSnapshotRecord.swift`
  - Persist trigger metadata so cached rows explain why they were captured.

- Modify `falsoai-lens/Data/ScreenTextCache/RealtimeScreenTextCacheMigrations.swift`
  - Add a lightweight migration for the trigger columns.

- Modify `falsoai-lens/Pipelines/Vision/Services/RealtimeScreenTextSampler.swift`
  - Add `sample(trigger:)`.
  - Prefer focused-window capture for focused-window targets.
  - Fall back to all-display capture when window capture fails.

- Modify `falsoai-lens/Pipelines/Vision/Services/RealtimeScreenTextPipeline.swift`
  - Replace the 2-second all-display loop with an event loop over `FocusedWindowObserver`.
  - Add debouncing and a 10-second focused-window heartbeat.
  - Preserve duplicate skipping by aggregate text/layout hash.

- Modify `falsoai-lens/ContentView.swift`
  - Show capture mode, last trigger reason, and whether the last sample captured focused window or all displays.
  - Keep existing cached text display.

---

### Task 1: Add Trigger Models

**Files:**

- Create: `falsoai-lens/Pipelines/Vision/Models/ScreenTextCaptureTrigger.swift`

- [ ] **Step 1: Create trigger model**

Create:

```swift
import CoreGraphics
import Foundation

enum ScreenTextCaptureTriggerReason: String, Codable, Equatable, Sendable {
    case activeApplicationChanged
    case focusedWindowChanged
    case windowMoved
    case windowResized
    case windowTitleChanged
    case fallbackHeartbeat
    case manualSample
}

enum ScreenTextCaptureTargetKind: String, Codable, Equatable, Sendable {
    case focusedWindow
    case allDisplays
}

struct ScreenTextCaptureTrigger: Equatable, Sendable {
    let id: UUID
    let occurredAt: Date
    let reason: ScreenTextCaptureTriggerReason
    let targetKind: ScreenTextCaptureTargetKind
    let processID: pid_t?
    let applicationName: String?
    let windowTitle: String?
    let windowBounds: CGRect?

    init(
        id: UUID = UUID(),
        occurredAt: Date = Date(),
        reason: ScreenTextCaptureTriggerReason,
        targetKind: ScreenTextCaptureTargetKind,
        processID: pid_t? = nil,
        applicationName: String? = nil,
        windowTitle: String? = nil,
        windowBounds: CGRect? = nil
    ) {
        self.id = id
        self.occurredAt = occurredAt
        self.reason = reason
        self.targetKind = targetKind
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
xcrun swiftc falsoai-lens/Pipelines/Vision/Models/ScreenTextCaptureTrigger.swift -typecheck
```

Expected: no output and exit code 0.

---

### Task 2: Add Focused Window Observer

**Files:**

- Create: `falsoai-lens/Pipelines/Vision/Services/FocusedWindowObserver.swift`

- [ ] **Step 1: Implement observer**

Create a `@MainActor final class FocusedWindowObserver` with:

- `func start() -> AsyncStream<ScreenTextCaptureTrigger>`
- `func stop()`
- `func currentFocusedWindowTrigger(reason:) -> ScreenTextCaptureTrigger`
- `private func installWorkspaceObserver()`
- `private func installAccessibilityObserver(for app: NSRunningApplication)`
- `private func focusedWindowMetadata(for pid: pid_t) -> (title: String?, bounds: CGRect?)`

Implementation requirements:

- Use `NSWorkspace.shared.notificationCenter` for `NSWorkspace.didActivateApplicationNotification`.
- On activation, emit `.activeApplicationChanged` with target `.focusedWindow`.
- If `AXIsProcessTrusted()` is false, still emit app activation triggers but mark `windowTitle` and `windowBounds` nil.
- When trusted, create `AXObserver` for the active app PID.
- Register:
  - `kAXFocusedWindowChangedNotification`
  - `kAXWindowMovedNotification`
  - `kAXWindowResizedNotification`
  - `kAXTitleChangedNotification`
- Add the observer run loop source to `.commonModes`.
- In the AX callback, hop back to `MainActor` before yielding the stream continuation.
- Remove notification observers and AX run-loop source in `stop()`.

- [ ] **Step 2: Add a temporary smoke harness**

Create `/private/tmp/falsoai-lens-focused-window-observer-tests/main.swift`:

```swift
import AppKit
import Foundation

let observer = FocusedWindowObserver()
let stream = observer.start()
var iterator = stream.makeAsyncIterator()

Task {
    try? await Task.sleep(nanoseconds: 500_000_000)
    observer.stop()
    exit(0)
}

if let event = await iterator.next() {
    print("Received trigger: \(event.reason.rawValue)")
} else {
    print("Observer started and stopped without trigger")
}
```

Run:

```bash
xcrun swiftc \
  falsoai-lens/Pipelines/Vision/Models/ScreenTextCaptureTrigger.swift \
  falsoai-lens/Pipelines/Vision/Services/FocusedWindowObserver.swift \
  /private/tmp/falsoai-lens-focused-window-observer-tests/main.swift \
  -o /private/tmp/falsoai-lens-focused-window-observer-tests/check
```

Expected:

- Compiles.
- Running the executable prints either a trigger or `Observer started and stopped without trigger`.

---

### Task 3: Add Focused Window Capture

**Files:**

- Modify: `falsoai-lens/Pipelines/Vision/Services/ScreenCaptureService.swift`

- [ ] **Step 1: Add window frame model**

Below `CapturedDisplayFrame`, add:

```swift
struct CapturedWindowFrame: Identifiable {
    var id: UInt32 { windowID }

    let windowID: UInt32
    let displayID: UInt32?
    let processID: pid_t?
    let applicationName: String?
    let windowTitle: String?
    let frame: CGRect
    let image: CGImage
}
```

- [ ] **Step 2: Add focused-window capture method**

Inside `ScreenCaptureService`, add:

```swift
func captureFocusedWindowImage(for trigger: ScreenTextCaptureTrigger) async throws -> CapturedWindowFrame {
    try prepareForCapture()

    let content = try await SCShareableContent.current
    guard let window = bestMatchingWindow(in: content.windows, trigger: trigger) else {
        throw ScreenCaptureError.noDisplayAvailable
    }

    return try await captureImage(for: window)
}
```

- [ ] **Step 3: Add `SCWindow` matching**

Add private method:

```swift
private func bestMatchingWindow(
    in windows: [SCWindow],
    trigger: ScreenTextCaptureTrigger
) -> SCWindow? {
    let candidateWindows = windows.filter { window in
        guard let processID = trigger.processID else { return false }
        return window.owningApplication?.processID == processID
    }

    if let windowTitle = trigger.windowTitle?.trimmingCharacters(in: .whitespacesAndNewlines),
       !windowTitle.isEmpty,
       let titleMatch = candidateWindows.first(where: {
           $0.title.localizedCaseInsensitiveContains(windowTitle)
               || windowTitle.localizedCaseInsensitiveContains($0.title)
       }) {
        return titleMatch
    }

    if let bounds = trigger.windowBounds,
       let boundsMatch = candidateWindows.min(by: {
           abs($0.frame.midX - bounds.midX) + abs($0.frame.midY - bounds.midY)
               < abs($1.frame.midX - bounds.midX) + abs($1.frame.midY - bounds.midY)
       }) {
        return boundsMatch
    }

    return candidateWindows.first
}
```

- [ ] **Step 4: Add `SCWindow` capture**

Add private method:

```swift
private func captureImage(for window: SCWindow) async throws -> CapturedWindowFrame {
    let filter = SCContentFilter(desktopIndependentWindow: window)
    let configuration = SCStreamConfiguration()
    configuration.width = Int(window.frame.width.rounded(.up))
    configuration.height = Int(window.frame.height.rounded(.up))
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
        displayID: nil,
        processID: window.owningApplication?.processID,
        applicationName: window.owningApplication?.applicationName,
        windowTitle: window.title,
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

If any `SCWindow` property names differ in the local SDK, inspect compile diagnostics and adjust only the property accessors.

---

### Task 4: Persist Trigger Metadata

**Files:**

- Modify: `falsoai-lens/Pipelines/Vision/Models/RealtimeScreenTextSnapshot.swift`
- Modify: `falsoai-lens/Data/ScreenTextCache/Records/RealtimeScreenTextSnapshotRecord.swift`
- Modify: `falsoai-lens/Data/ScreenTextCache/RealtimeScreenTextCacheMigrations.swift`
- Modify: `falsoai-lens/Data/ScreenTextCache/RealtimeScreenTextCache.swift`

- [ ] **Step 1: Add snapshot fields**

Add to `RealtimeScreenTextSnapshot`:

```swift
let triggerReason: ScreenTextCaptureTriggerReason
let captureTargetKind: ScreenTextCaptureTargetKind
let triggerApplicationName: String?
let triggerProcessID: pid_t?
let triggerWindowTitle: String?
```

- [ ] **Step 2: Add record fields**

Add to `RealtimeScreenTextSnapshotRecord`:

```swift
var triggerReason: String
var captureTargetKind: String
var triggerApplicationName: String?
var triggerProcessID: Int32?
var triggerWindowTitle: String?
```

- [ ] **Step 3: Add migration**

In `RealtimeScreenTextCacheMigrations`, add migration after table creation:

```swift
migrator.registerMigration("addRealtimeScreenTextTriggerMetadata") { db in
    try db.alter(table: RealtimeScreenTextSnapshotRecord.databaseTableName) { table in
        table.add(column: "triggerReason", .text).notNull().defaults(to: ScreenTextCaptureTriggerReason.manualSample.rawValue)
        table.add(column: "captureTargetKind", .text).notNull().defaults(to: ScreenTextCaptureTargetKind.allDisplays.rawValue)
        table.add(column: "triggerApplicationName", .text)
        table.add(column: "triggerProcessID", .integer)
        table.add(column: "triggerWindowTitle", .text)
    }
}
```

- [ ] **Step 4: Map cache save fields**

In `RealtimeScreenTextCache.save(_:)`, populate the new record fields from the snapshot:

```swift
triggerReason: snapshot.triggerReason.rawValue,
captureTargetKind: snapshot.captureTargetKind.rawValue,
triggerApplicationName: snapshot.triggerApplicationName,
triggerProcessID: snapshot.triggerProcessID,
triggerWindowTitle: snapshot.triggerWindowTitle
```

- [ ] **Step 5: Build**

Run:

```bash
xcodebuild -project falsoai-lens.xcodeproj -scheme falsoai-lens -configuration Debug build
```

Expected: `** BUILD SUCCEEDED **`.

---

### Task 5: Teach Sampler To Prefer Focused Window

**Files:**

- Modify: `falsoai-lens/Pipelines/Vision/Services/RealtimeScreenTextSampler.swift`

- [ ] **Step 1: Keep existing sample API as manual all-display wrapper**

Replace current `sample(sessionID:sequenceNumber:)` body with:

```swift
func sample(sessionID: UUID, sequenceNumber: Int) async throws -> RealtimeScreenTextSnapshot {
    try await sample(
        sessionID: sessionID,
        sequenceNumber: sequenceNumber,
        trigger: ScreenTextCaptureTrigger(
            reason: .manualSample,
            targetKind: .allDisplays
        )
    )
}
```

- [ ] **Step 2: Add trigger-aware sample method**

Add:

```swift
func sample(
    sessionID: UUID,
    sequenceNumber: Int,
    trigger: ScreenTextCaptureTrigger
) async throws -> RealtimeScreenTextSnapshot {
    switch trigger.targetKind {
    case .focusedWindow:
        do {
            return try await sampleFocusedWindow(
                sessionID: sessionID,
                sequenceNumber: sequenceNumber,
                trigger: trigger
            )
        } catch {
            logger.error("Focused window sample failed, falling back to all displays: \(String(describing: error), privacy: .public)")
            return try await sampleAllDisplays(
                sessionID: sessionID,
                sequenceNumber: sequenceNumber,
                trigger: ScreenTextCaptureTrigger(
                    reason: trigger.reason,
                    targetKind: .allDisplays,
                    processID: trigger.processID,
                    applicationName: trigger.applicationName,
                    windowTitle: trigger.windowTitle,
                    windowBounds: trigger.windowBounds
                )
            )
        }
    case .allDisplays:
        return try await sampleAllDisplays(
            sessionID: sessionID,
            sequenceNumber: sequenceNumber,
            trigger: trigger
        )
    }
}
```

- [ ] **Step 3: Extract current all-display code**

Move the current `sample(sessionID:sequenceNumber:)` implementation into:

```swift
private func sampleAllDisplays(
    sessionID: UUID,
    sequenceNumber: Int,
    trigger: ScreenTextCaptureTrigger
) async throws -> RealtimeScreenTextSnapshot
```

Set the new snapshot trigger fields from `trigger`.

- [ ] **Step 4: Add focused-window sample code**

Add:

```swift
private func sampleFocusedWindow(
    sessionID: UUID,
    sequenceNumber: Int,
    trigger: ScreenTextCaptureTrigger
) async throws -> RealtimeScreenTextSnapshot {
    let started = Date()
    let frame = try await screenCaptureService.captureFocusedWindowImage(for: trigger)
    let capturedAt = Date()
    let frameHash = ScreenTextHasher.hashStringForScreenTextWindow(
        windowID: frame.windowID,
        image: frame.image
    )
    let memory = memory(forDisplayID: frame.displayID ?? frame.windowID)

    let document: ScreenTextDocument
    var reusedDisplayCount = 0
    var ocrDisplayCount = 0
    if let cachedDocument = await memory.cachedDocument(forFrameHash: frameHash) {
        document = cachedDocument
        reusedDisplayCount = 1
    } else {
        let observations = try ocrService.recognizeTextObservations(in: frame.image)
        document = await memory.store(
            documentBuilder.build(
                observations: observations,
                frameSize: CGSize(width: CGFloat(frame.image.width), height: CGFloat(frame.image.height)),
                frameHash: frameHash,
                capturedAt: capturedAt
            )
        )
        ocrDisplayCount = 1
    }

    let aggregate = MultiDisplayScreenTextDocument(
        capturedAt: capturedAt,
        displays: [
            DisplayScreenTextDocument(displayID: frame.displayID ?? frame.windowID, index: 0, document: document)
        ]
    )

    return try makeSnapshot(
        sessionID: sessionID,
        sequenceNumber: sequenceNumber,
        capturedAt: capturedAt,
        document: aggregate,
        trigger: trigger,
        displayFrameHashes: [frameHash],
        reusedDisplayCount: reusedDisplayCount,
        ocrDisplayCount: ocrDisplayCount,
        elapsedSeconds: Date().timeIntervalSince(started)
    )
}
```

- [ ] **Step 5: Add shared snapshot factory**

Add a private `makeSnapshot(...) throws -> RealtimeScreenTextSnapshot` that performs export, markdown, compact JSON, chunks, aggregate hashes, and trigger metadata once.

- [ ] **Step 6: Add window hash helper**

In `ScreenTextHasher`, add:

```swift
static func hashWindowFrame(windowID: UInt32, image: CGImage) -> String {
    hashString("window:\(windowID)|frame:\(hashFrame(image))")
}
```

Use `hashWindowFrame(windowID:image:)` in focused-window sampling.

- [ ] **Step 7: Build**

Run:

```bash
xcodebuild -project falsoai-lens.xcodeproj -scheme falsoai-lens -configuration Debug build
```

Expected: `** BUILD SUCCEEDED **`.

---

### Task 6: Replace Fixed 2-Second Loop With Event Loop

**Files:**

- Modify: `falsoai-lens/Pipelines/Vision/Services/RealtimeScreenTextPipeline.swift`

- [ ] **Step 1: Add observer and debounce properties**

Add:

```swift
private let focusedWindowObserver: FocusedWindowObserver
private let debounceNanoseconds: UInt64
private let fallbackHeartbeatSeconds: TimeInterval
private var heartbeatTask: Task<Void, Never>?
```

Initialize:

```swift
focusedWindowObserver: FocusedWindowObserver = FocusedWindowObserver(),
debounceNanoseconds: UInt64 = 350_000_000,
fallbackHeartbeatSeconds: TimeInterval = 10
```

- [ ] **Step 2: Replace `runLoop()`**

Replace the current sleep loop with:

```swift
private func runLoop() async {
    let stream = focusedWindowObserver.start()
    startFallbackHeartbeat()

    for await trigger in stream {
        if Task.isCancelled { break }
        await debounce()
        await captureOneSample(trigger: trigger)
    }

    focusedWindowObserver.stop()
    heartbeatTask?.cancel()
    heartbeatTask = nil
}
```

- [ ] **Step 3: Add heartbeat**

Add:

```swift
private func startFallbackHeartbeat() {
    heartbeatTask?.cancel()
    heartbeatTask = Task { [weak self] in
        while !Task.isCancelled {
            guard let self else { return }
            let nanoseconds = UInt64(self.fallbackHeartbeatSeconds * 1_000_000_000)
            try? await Task.sleep(nanoseconds: nanoseconds)
            if Task.isCancelled { break }
            let trigger = self.focusedWindowObserver.currentFocusedWindowTrigger(reason: .fallbackHeartbeat)
            await self.captureOneSample(trigger: trigger)
        }
    }
}
```

- [ ] **Step 4: Add debounce**

Add:

```swift
private func debounce() async {
    try? await Task.sleep(nanoseconds: debounceNanoseconds)
}
```

- [ ] **Step 5: Change capture method signature**

Replace `captureOneSample()` with:

```swift
private func captureOneSample(trigger: ScreenTextCaptureTrigger)
```

Call:

```swift
let snapshot = try await sampler.sample(
    sessionID: sessionID,
    sequenceNumber: sequenceNumber,
    trigger: trigger
)
```

Update status strings to include `trigger.reason.rawValue`.

- [ ] **Step 6: Stop observers**

In `stop()`, add:

```swift
focusedWindowObserver.stop()
heartbeatTask?.cancel()
heartbeatTask = nil
```

- [ ] **Step 7: Build**

Run:

```bash
xcodebuild -project falsoai-lens.xcodeproj -scheme falsoai-lens -configuration Debug build
```

Expected: `** BUILD SUCCEEDED **`.

---

### Task 7: Update UI For Selective Capture

**Files:**

- Modify: `falsoai-lens/ContentView.swift`

- [ ] **Step 1: Add trigger metadata to realtime panel**

In `realtimeScreenTextPanel`, when `latestSnapshot` exists, display:

```swift
Text("\(latestSnapshot.captureTargetKind.rawValue) | \(latestSnapshot.triggerReason.rawValue) | \(latestSnapshot.triggerApplicationName ?? "Unknown app")")
    .font(.caption)
    .foregroundStyle(.secondary)
    .textSelection(.enabled)
```

- [ ] **Step 2: Add cached row metadata**

In the realtime sidebar and cached-text section, display:

```swift
Text("\(snapshot.captureTargetKind) | \(snapshot.triggerReason)")
    .font(.caption)
    .foregroundStyle(.secondary)
```

- [ ] **Step 3: Update labels**

Change status label copy from generic "Realtime Screen Text" to "Selective Screen Text" only if the UI still has enough room. Keep existing layout and avoid adding a new settings surface.

- [ ] **Step 4: Build**

Run:

```bash
xcodebuild -project falsoai-lens.xcodeproj -scheme falsoai-lens -configuration Debug build
```

Expected: `** BUILD SUCCEEDED **`.

---

### Task 8: Manual Verification

**Files:**

- No code files.

- [ ] **Step 1: Launch app**

Run from Xcode or the built Debug app.

- [ ] **Step 2: Permissions**

Verify:

- Screen Recording is authorized.
- Accessibility is authorized for focused-window metadata and AX notifications.

- [ ] **Step 3: Start selective realtime recording**

Click `Start`.

Expected:

- Status changes to recording.
- A first sample appears after app/window focus event or first fallback heartbeat.

- [ ] **Step 4: Switch active apps**

Switch from the app to Safari, Notes, or another text-heavy app.

Expected:

- A cached sample is created because `.activeApplicationChanged` or `.focusedWindowChanged` fires.
- UI shows trigger reason and app name.

- [ ] **Step 5: Move or resize the focused window**

Move or resize the focused window.

Expected:

- A sample is attempted after debounce.
- Duplicate skipping prevents cache spam if OCR text/layout is unchanged.

- [ ] **Step 6: Edit text inside the same focused window**

Type into a document without changing windows.

Expected:

- If the app emits AX title/focus notifications, a sample may happen quickly.
- Otherwise the fallback heartbeat captures the change within about 10 seconds.

- [ ] **Step 7: Stop recording**

Click `Stop`.

Expected:

- AX observers stop.
- Heartbeat stops.
- Cache remains persisted until Clear Cache is clicked.

---

## Expected Behavior After This Plan

- Normal idle state: no full-display screenshot every 2 seconds.
- App/window focus changes: capture focused window when possible.
- Window move/resize/title/focus events: capture focused window after debounce.
- Unobservable text changes inside the same window: captured by focused-window heartbeat about every 10 seconds.
- Focused-window capture failure: falls back to all-display capture.
- Cache writes: still only when readable text exists and text/layout hash changed.
- Cache deletion: still only through Clear Cache unless a separate retention plan is added.

## Self-Review

Spec coverage:

- The plan replaces blind sampling with active app/window event triggers.
- The plan keeps a correctness fallback for text changes macOS cannot emit as events.
- The plan preserves existing OCR/cache/export architecture.
- The plan exposes trigger metadata in UI and cache records.

Placeholder scan:

- No placeholder or vague implementation steps are present.

Type consistency:

- `ScreenTextCaptureTrigger` feeds `FocusedWindowObserver`, `ScreenCaptureService`, `RealtimeScreenTextSampler`, and `RealtimeScreenTextPipeline`.
- Trigger metadata added to `RealtimeScreenTextSnapshot` is persisted by `RealtimeScreenTextSnapshotRecord`.
- The UI reads trigger metadata from both live snapshots and cached records.
