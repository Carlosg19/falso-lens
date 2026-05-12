# All-Display One-Second Sampling With Cache Deduplication Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace focused-window screen text sampling with all-display sampling every second, while skipping duplicate cache writes by checking the persisted cache.

**Architecture:** The realtime pipeline should always capture all displays through `ScreenCaptureService.captureAllDisplayImages()`. Keep the existing per-display frame memory so unchanged display frames can reuse OCR documents, and add a GRDB-backed duplicate lookup so snapshots already present in the cache are not saved again. Remove focused-window-only capture and UI metadata because the capture target becomes fixed: all screens.

**Tech Stack:** Swift, SwiftUI, ScreenCaptureKit, Vision OCR, GRDB, Swift concurrency, macOS permissions.

---

## Why This Plan

The focused-window sampler depends on Accessibility permission and `SCWindow` matching. The new requirement is simpler and more predictable:

- sample all screens,
- run once per second while recording,
- avoid duplicate cache entries by checking persisted cache fingerprints.

This restores reliable screen-wide coverage and removes the focused-window permission sensitivity. It keeps the useful optimization layers already present:

- per-display frame hashing avoids repeated OCR for unchanged images during a run,
- aggregate text/layout hashing avoids repeated cache writes,
- the new cache lookup avoids duplicate saved rows across non-adjacent repeated screen states and app restarts.

## File Structure

- Delete `falsoai-lens/Pipelines/Vision/Services/FocusedWindowResolver.swift`
  - No longer needed because capture does not inspect the focused window.

- Modify `falsoai-lens/Pipelines/Vision/Models/FocusedWindowCaptureTarget.swift`
  - Replace with a smaller file or delete it after moving/removing any remaining target types.
  - Preferred outcome: remove the file and remove capture-target metadata from snapshots/cache/UI.

- Modify `falsoai-lens/Pipelines/Vision/Services/ScreenCaptureService.swift`
  - Remove `CapturedWindowFrame`.
  - Remove `captureFocusedWindowImage(target:)`.
  - Remove `bestMatchingWindow(in:target:)`.
  - Remove private window `captureImage(for:target:)`.
  - Keep `CapturedDisplayFrame`, `captureAllDisplayImages()`, and `captureMainDisplayImage()`.

- Modify `falsoai-lens/Pipelines/Vision/Services/ScreenTextHasher.swift`
  - Remove `windowFrameHash(windowID:image:)`.
  - Keep `displayFrameHash(displayID:image:)`.

- Modify `falsoai-lens/Pipelines/Vision/Models/RealtimeScreenTextSnapshot.swift`
  - Remove focused-window/all-display metadata fields.

- Modify `falsoai-lens/Data/ScreenTextCache/Records/RealtimeScreenTextSnapshotRecord.swift`
  - Keep existing capture target columns if migration history already created them, but stop depending on them in new logic.
  - To reduce churn, do not drop columns from existing databases.

- Modify `falsoai-lens/Data/ScreenTextCache/RealtimeScreenTextCacheMigrations.swift`
  - Keep previous migrations intact if already present.
  - Add no migration for duplicate checking because the existing `aggregateTextHash, aggregateLayoutHash` index supports the query.

- Modify `falsoai-lens/Data/ScreenTextCache/RealtimeScreenTextCache.swift`
  - Add a cache duplicate lookup using aggregate text/layout hashes.
  - Stop writing capture target metadata if snapshot fields are removed; if record columns remain non-null, write fixed defaults inside the record creation.

- Modify `falsoai-lens/Pipelines/Vision/Services/RealtimeScreenTextSampler.swift`
  - Remove focused-window resolver dependency.
  - Remove focused-window sample path.
  - Make `sample(sessionID:sequenceNumber:)` always use all-display capture.

- Modify `falsoai-lens/Pipelines/Vision/Services/RealtimeScreenTextPipeline.swift`
  - Keep default interval at `1`.
  - Clamp minimum to `1`, not `0.75`, so behavior matches “scans the screens every second.”
  - Replace in-memory-only duplicate logic with cache-backed duplicate logic.

- Modify `falsoai-lens/ContentView.swift`
  - Remove focused-window metadata display lines from realtime and cached text panels.
  - Keep counters, cache text display, and clear cache controls.

---

### Task 1: Remove Focused-Window Capture Types And Services

**Files:**

- Delete: `falsoai-lens/Pipelines/Vision/Services/FocusedWindowResolver.swift`
- Delete: `falsoai-lens/Pipelines/Vision/Models/FocusedWindowCaptureTarget.swift`
- Modify: `falsoai-lens/Pipelines/Vision/Services/ScreenCaptureService.swift`
- Modify: `falsoai-lens/Pipelines/Vision/Services/ScreenTextHasher.swift`

- [ ] **Step 1: Delete focused-window-only files**

Delete these files:

```bash
rm falsoai-lens/Pipelines/Vision/Services/FocusedWindowResolver.swift
rm falsoai-lens/Pipelines/Vision/Models/FocusedWindowCaptureTarget.swift
```

- [ ] **Step 2: Remove window capture model**

In `falsoai-lens/Pipelines/Vision/Services/ScreenCaptureService.swift`, remove this whole type:

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

- [ ] **Step 3: Remove focused-window capture methods**

In `falsoai-lens/Pipelines/Vision/Services/ScreenCaptureService.swift`, remove these methods completely:

```swift
func captureFocusedWindowImage(target: FocusedWindowCaptureTarget) async throws -> CapturedWindowFrame
```

```swift
private func bestMatchingWindow(
    in windows: [SCWindow],
    target: FocusedWindowCaptureTarget
) -> SCWindow?
```

```swift
private func captureImage(
    for window: SCWindow,
    target: FocusedWindowCaptureTarget
) async throws -> CapturedWindowFrame
```

After the edit, `ScreenCaptureService` should still contain:

```swift
func captureAllDisplayImages() async throws -> [CapturedDisplayFrame]
func captureMainDisplayImage() async throws -> CGImage
private func captureImage(for display: SCDisplay, index: Int) async throws -> CapturedDisplayFrame
func stop() async
```

- [ ] **Step 4: Remove window frame hashing**

In `falsoai-lens/Pipelines/Vision/Services/ScreenTextHasher.swift`, remove:

```swift
static func windowFrameHash(windowID: UInt32, image: CGImage) -> String {
    hashString("window:\(windowID)|frame:\(hashFrame(image))")
}
```

- [ ] **Step 5: Build**

Run:

```bash
xcodebuild -project falsoai-lens.xcodeproj -scheme falsoai-lens -configuration Debug build
```

Expected: build may fail because sampler/snapshot still reference removed focused-window types. Continue to Task 2 and use the diagnostics to confirm all references are being removed.

---

### Task 2: Simplify Snapshot And Cache Record Capture Metadata

**Files:**

- Modify: `falsoai-lens/Pipelines/Vision/Models/RealtimeScreenTextSnapshot.swift`
- Modify: `falsoai-lens/Data/ScreenTextCache/Records/RealtimeScreenTextSnapshotRecord.swift`
- Modify: `falsoai-lens/Data/ScreenTextCache/RealtimeScreenTextCache.swift`

- [ ] **Step 1: Remove snapshot capture-target fields**

In `RealtimeScreenTextSnapshot`, remove:

```swift
let captureTargetKind: ScreenTextCaptureTargetKind
let captureApplicationName: String?
let captureProcessID: pid_t?
let captureWindowTitle: String?
```

The final struct should be:

```swift
import Foundation

struct RealtimeScreenTextSnapshot: Identifiable, Equatable, Sendable {
    var id: String { "\(sessionID.uuidString)-\(sequenceNumber)" }

    let sessionID: UUID
    let sequenceNumber: Int
    let capturedAt: Date
    let document: MultiDisplayScreenTextDocument
    let recognizedText: String
    let markdownExport: String
    let compactJSONExport: String
    let chunkCount: Int
    let displayCount: Int
    let observationCount: Int
    let lineCount: Int
    let blockCount: Int
    let regionCount: Int
    let aggregateTextHash: String
    let aggregateLayoutHash: String
    let displayFrameHashes: [String]
    let reusedDisplayCount: Int
    let ocrDisplayCount: Int
    let elapsedSeconds: Double

    var hasReadableText: Bool {
        !recognizedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
```

- [ ] **Step 2: Keep record columns but treat them as compatibility fields**

In `RealtimeScreenTextSnapshotRecord`, keep these properties if they already exist:

```swift
var captureTargetKind: String
var captureApplicationName: String?
var captureProcessID: Int32?
var captureWindowTitle: String?
```

Reason: existing migrated databases may already have non-null `captureTargetKind`. Keeping compatibility fields avoids a destructive migration. New writes will use fixed all-display defaults in Step 3.

- [ ] **Step 3: Save fixed all-display metadata for compatibility**

In `RealtimeScreenTextCache.save(_:)`, replace any snapshot-derived capture metadata arguments with fixed all-display values:

```swift
captureTargetKind: "allDisplays",
captureApplicationName: nil,
captureProcessID: nil,
captureWindowTitle: nil
```

The tail of `RealtimeScreenTextSnapshotRecord(...)` should be:

```swift
displayFrameHashesJSON: displayFrameHashesJSON,
reusedDisplayCount: snapshot.reusedDisplayCount,
ocrDisplayCount: snapshot.ocrDisplayCount,
elapsedSeconds: snapshot.elapsedSeconds,
captureTargetKind: "allDisplays",
captureApplicationName: nil,
captureProcessID: nil,
captureWindowTitle: nil
```

- [ ] **Step 4: Build**

Run:

```bash
xcodebuild -project falsoai-lens.xcodeproj -scheme falsoai-lens -configuration Debug build
```

Expected: build may still fail because the sampler and UI still reference removed snapshot fields. Continue to Task 3.

---

### Task 3: Make The Sampler All-Display Only

**Files:**

- Modify: `falsoai-lens/Pipelines/Vision/Services/RealtimeScreenTextSampler.swift`

- [ ] **Step 1: Remove resolver property and initializer parameter**

In `RealtimeScreenTextSampler`, remove:

```swift
private let focusedWindowResolver: FocusedWindowResolver
```

Change the initializer from:

```swift
init(
    screenCaptureService: ScreenCaptureService? = nil,
    ocrService: OCRService? = nil,
    documentBuilder: ScreenTextDocumentBuilder? = nil,
    exporter: ScreenTextLLMExporter? = nil,
    focusedWindowResolver: FocusedWindowResolver? = nil
) {
    self.screenCaptureService = screenCaptureService ?? ScreenCaptureService()
    self.ocrService = ocrService ?? OCRService()
    self.documentBuilder = documentBuilder ?? ScreenTextDocumentBuilder()
    self.exporter = exporter ?? ScreenTextLLMExporter()
    self.focusedWindowResolver = focusedWindowResolver ?? FocusedWindowResolver()
}
```

to:

```swift
init(
    screenCaptureService: ScreenCaptureService? = nil,
    ocrService: OCRService? = nil,
    documentBuilder: ScreenTextDocumentBuilder? = nil,
    exporter: ScreenTextLLMExporter? = nil
) {
    self.screenCaptureService = screenCaptureService ?? ScreenCaptureService()
    self.ocrService = ocrService ?? OCRService()
    self.documentBuilder = documentBuilder ?? ScreenTextDocumentBuilder()
    self.exporter = exporter ?? ScreenTextLLMExporter()
}
```

- [ ] **Step 2: Replace sample entry point with all-display body**

Replace:

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

with:

```swift
func sample(sessionID: UUID, sequenceNumber: Int) async throws -> RealtimeScreenTextSnapshot {
    try await sampleAllDisplays(
        sessionID: sessionID,
        sequenceNumber: sequenceNumber
    )
}
```

- [ ] **Step 3: Delete focused-window sample implementation**

Remove this entire method:

```swift
private func sampleFocusedWindow(
    sessionID: UUID,
    sequenceNumber: Int,
    target: FocusedWindowCaptureTarget
) async throws -> RealtimeScreenTextSnapshot
```

- [ ] **Step 4: Remove capture-target parameters from snapshot factory**

Change `makeSnapshot` signature from:

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
) throws -> RealtimeScreenTextSnapshot
```

to:

```swift
private func makeSnapshot(
    sessionID: UUID,
    sequenceNumber: Int,
    capturedAt: Date,
    document: MultiDisplayScreenTextDocument,
    displayFrameHashes: [String],
    reusedDisplayCount: Int,
    ocrDisplayCount: Int,
    elapsedSeconds: Double
) throws -> RealtimeScreenTextSnapshot
```

- [ ] **Step 5: Update all-display call to snapshot factory**

In `sampleAllDisplays`, change:

```swift
return try makeSnapshot(
    sessionID: sessionID,
    sequenceNumber: sequenceNumber,
    capturedAt: capturedAt,
    document: document,
    displayFrameHashes: displayFrameHashes,
    reusedDisplayCount: reusedDisplayCount,
    ocrDisplayCount: ocrDisplayCount,
    elapsedSeconds: Date().timeIntervalSince(started),
    captureTargetKind: .allDisplays,
    captureApplicationName: nil,
    captureProcessID: nil,
    captureWindowTitle: nil
)
```

to:

```swift
return try makeSnapshot(
    sessionID: sessionID,
    sequenceNumber: sequenceNumber,
    capturedAt: capturedAt,
    document: document,
    displayFrameHashes: displayFrameHashes,
    reusedDisplayCount: reusedDisplayCount,
    ocrDisplayCount: ocrDisplayCount,
    elapsedSeconds: Date().timeIntervalSince(started)
)
```

- [ ] **Step 6: Remove capture-target arguments from snapshot construction**

Inside `makeSnapshot`, change the `RealtimeScreenTextSnapshot(...)` initializer tail from:

```swift
displayFrameHashes: displayFrameHashes,
reusedDisplayCount: reusedDisplayCount,
ocrDisplayCount: ocrDisplayCount,
elapsedSeconds: elapsedSeconds,
captureTargetKind: captureTargetKind,
captureApplicationName: captureApplicationName,
captureProcessID: captureProcessID,
captureWindowTitle: captureWindowTitle
```

to:

```swift
displayFrameHashes: displayFrameHashes,
reusedDisplayCount: reusedDisplayCount,
ocrDisplayCount: ocrDisplayCount,
elapsedSeconds: elapsedSeconds
```

- [ ] **Step 7: Build**

Run:

```bash
xcodebuild -project falsoai-lens.xcodeproj -scheme falsoai-lens -configuration Debug build
```

Expected: build may still fail because pipeline/UI still reference `captureTargetKind`. Continue to Task 4.

---

### Task 4: Add Cache-Backed Duplicate Detection

**Files:**

- Modify: `falsoai-lens/Data/ScreenTextCache/RealtimeScreenTextCache.swift`
- Modify: `falsoai-lens/Pipelines/Vision/Services/RealtimeScreenTextPipeline.swift`

- [ ] **Step 1: Add duplicate lookup to cache actor**

In `RealtimeScreenTextCache`, add this method below `fetchRecent(limit:)`:

```swift
func containsSnapshot(
    textHash: String,
    layoutHash: String
) throws -> Bool {
    try database.dbQueue.read { db in
        try Int.fetchOne(
            db,
            sql: """
                SELECT COUNT(*)
                FROM realtime_screen_text_snapshots
                WHERE aggregateTextHash = ?
                  AND aggregateLayoutHash = ?
                LIMIT 1
                """,
            arguments: [textHash, layoutHash]
        ) ?? 0 > 0
    }
}
```

- [ ] **Step 2: Keep sample interval exactly one second**

In `RealtimeScreenTextPipeline.init(...)`, keep:

```swift
sampleIntervalSeconds: TimeInterval = 1
```

Change:

```swift
self.sampleIntervalSeconds = max(0.75, sampleIntervalSeconds)
```

to:

```swift
self.sampleIntervalSeconds = max(1, sampleIntervalSeconds)
```

- [ ] **Step 3: Make duplicate check async and cache-backed**

Replace:

```swift
private func shouldCache(_ snapshot: RealtimeScreenTextSnapshot) -> Bool {
    snapshot.aggregateTextHash != lastCachedTextHash
        || snapshot.aggregateLayoutHash != lastCachedLayoutHash
}
```

with:

```swift
private func shouldCache(_ snapshot: RealtimeScreenTextSnapshot) async throws -> Bool {
    if snapshot.aggregateTextHash == lastCachedTextHash,
       snapshot.aggregateLayoutHash == lastCachedLayoutHash {
        return false
    }

    guard let cache else {
        return true
    }

    let cacheContainsSnapshot = try await cache.containsSnapshot(
        textHash: snapshot.aggregateTextHash,
        layoutHash: snapshot.aggregateLayoutHash
    )
    return !cacheContainsSnapshot
}
```

- [ ] **Step 4: Await duplicate check before saving**

In `captureOneSample()`, replace:

```swift
guard shouldCache(snapshot) else {
    duplicateSamplesSkipped += 1
    statusText = "Screen text unchanged; skipped duplicate sample \(sequenceNumber)."
    return
}
```

with:

```swift
guard try await shouldCache(snapshot) else {
    duplicateSamplesSkipped += 1
    statusText = "Screen text already cached; skipped duplicate sample \(sequenceNumber)."
    return
}
```

- [ ] **Step 5: Remove focused-window status text**

In `captureOneSample()`, replace:

```swift
let targetLabel = snapshot.captureTargetKind == .focusedWindow ? "focused window" : "all displays"
statusText = "Cached \(targetLabel) sample \(sequenceNumber) with \(snapshot.recognizedText.count) characters."
```

with:

```swift
statusText = "Cached all-screen sample \(sequenceNumber) with \(snapshot.recognizedText.count) characters."
```

- [ ] **Step 6: Build**

Run:

```bash
xcodebuild -project falsoai-lens.xcodeproj -scheme falsoai-lens -configuration Debug build
```

Expected: build may still fail because `ContentView` references capture metadata. Continue to Task 5.

---

### Task 5: Remove Focused-Window Metadata From UI

**Files:**

- Modify: `falsoai-lens/ContentView.swift`

- [ ] **Step 1: Remove latest snapshot target metadata line**

In `realtimeScreenTextPanel`, remove this block:

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

- [ ] **Step 2: Remove cached snapshot target metadata line**

In `realtimeCachedTextSection`, remove this block:

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

- [ ] **Step 3: Keep display count wording**

Confirm this existing cached metadata row remains:

```swift
HStack(spacing: 12) {
    Label("\(cachedSnapshot.displayCount) displays", systemImage: "display.2")
    Label("\(cachedText.count) chars", systemImage: "textformat.size")
    Label(cachedSnapshot.capturedAt.formatted(date: .omitted, time: .standard), systemImage: "clock")
}
.font(.caption)
.foregroundStyle(.secondary)
```

- [ ] **Step 4: Build**

Run:

```bash
xcodebuild -project falsoai-lens.xcodeproj -scheme falsoai-lens -configuration Debug build
```

Expected: `** BUILD SUCCEEDED **`.

---

### Task 6: Verify One-Second All-Screen Behavior

**Files:**

- No source file changes.

- [ ] **Step 1: Run final build**

Run:

```bash
xcodebuild -project falsoai-lens.xcodeproj -scheme falsoai-lens -configuration Debug build
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 2: Check for removed focused-window references**

Run:

```bash
rg -n "FocusedWindow|focusedWindow|captureFocusedWindow|windowFrameHash|captureTargetKind|captureApplicationName|captureWindowTitle" falsoai-lens
```

Expected: no output, unless compatibility-only record properties are intentionally retained. If compatibility-only record properties remain, the only acceptable matches are in:

```text
falsoai-lens/Data/ScreenTextCache/Records/RealtimeScreenTextSnapshotRecord.swift
falsoai-lens/Data/ScreenTextCache/RealtimeScreenTextCacheMigrations.swift
falsoai-lens/Data/ScreenTextCache/RealtimeScreenTextCache.swift
```

- [ ] **Step 3: Manual run**

Launch the app from Xcode and open the realtime screen text panel.

Expected:

- The panel shows recording after pressing `Start`.
- Status says it is reading sample `1`, `2`, `3`, and so on.
- Samples are spaced at roughly one second plus capture/OCR time.
- The app does not show focused-window/app/window metadata.

- [ ] **Step 4: Verify cache deduplication behavior**

With a static screen, press `Start` and leave recording active for at least 5 seconds.

Expected:

- `samplesCaptured` increases for each sampled second.
- `snapshotsCached` increases for the first readable screen state.
- `duplicateSamplesSkipped` increases for repeated screen states.
- The cached text section does not fill with identical repeated entries.

- [ ] **Step 5: Verify cache lookup catches older duplicates**

Change visible screen text, wait for a cache write, then return to a previously cached screen state.

Expected:

- The repeated older screen state is skipped with status:

```text
Screen text already cached; skipped duplicate sample N.
```

- The cache does not save a second row with the same aggregate text hash and aggregate layout hash.

---

## Expected Behavior After This Plan

- The realtime recorder samples all displays only.
- Sampling interval is fixed at one second minimum.
- OCR reuse still happens per display when frame hashes are unchanged.
- Cache writes are skipped when the same aggregate text/layout fingerprint already exists in the database.
- Accessibility permission is no longer needed for realtime screen text capture.
- Focused-window metadata no longer appears in the realtime UI.

## Self-Review

Spec coverage:

- “Only scans the screens every second” is handled by all-display-only sampler logic and the `max(1, sampleIntervalSeconds)` clamp.
- “Check for duplicates in the cache” is handled by `RealtimeScreenTextCache.containsSnapshot(textHash:layoutHash:)`.
- “Optimize caching” is handled by checking persisted aggregate hashes before saving.

Placeholder scan:

- No placeholder implementation language is intentionally left in this plan.

Type consistency:

- `RealtimeScreenTextSnapshot` no longer exposes capture-target metadata.
- `RealtimeScreenTextSampler` no longer references `FocusedWindowResolver`, `FocusedWindowCaptureTarget`, or `ScreenTextCaptureTargetKind`.
- `RealtimeScreenTextPipeline.shouldCache(_:)` becomes async because it queries the cache actor.
- `RealtimeScreenTextCache.containsSnapshot(textHash:layoutHash:)` uses existing aggregate hash columns and their existing index.
