# Five-Minute Screen Text Encounter Memory Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Keep a privacy-preserving rolling five-minute memory of every unique line of screen text the user came into contact with, while removing duplicates.

**Architecture:** Keep the realtime all-display sampler and GRDB snapshot cache as separate layers. Add an in-memory `ScreenTextEncounterMemory` actor that ingests each readable `RealtimeScreenTextSnapshot`, deduplicates line-level text by normalized text hash, tracks first/last seen timestamps and seen counts, and prunes entries outside the five-minute window. Surface the rolling encounter memory in `ContentView` as the primary "all text from the last five minutes" view.

**Tech Stack:** Swift, SwiftUI, ScreenCaptureKit, Vision OCR, Swift actors, existing `ScreenTextHasher`, existing realtime screen-text pipeline.

---

## Scope And Assumptions

This plan builds on the current all-display realtime sampling path:

- `RealtimeScreenTextSampler.sample(sessionID:sequenceNumber:)` captures all displays.
- `RealtimeScreenTextPipeline` samples every second.
- `RealtimeScreenTextCache.containsSnapshot(textHash:layoutHash:)` skips duplicate persisted snapshots.
- `ScreenTextMemory` already avoids rerunning OCR for unchanged display frames.

The five-minute encounter memory is intentionally **in memory only**. This matches the app's local-first privacy stance and avoids creating a second durable screen-text history. The existing GRDB snapshot cache remains available for recent changed screen states.

The first version deduplicates at **line level** because lines are readable, searchable, and less coarse than whole snapshots or blocks. If a display has no lines, the memory falls back to OCR observations so text is not silently lost.

## File Structure

- Create `falsoai-lens/Pipelines/Vision/Models/ScreenTextEncounter.swift`
  - Defines the value shown in the UI: text, normalized hash, first seen time, last seen time, seen count, and latest source location.

- Create `falsoai-lens/Pipelines/Vision/Services/ScreenTextEncounterMemory.swift`
  - Actor that owns the rolling five-minute memory.
  - Ingests snapshots.
  - Deduplicates text units.
  - Prunes stale entries.
  - Exposes sorted recent encounters.

- Modify `falsoai-lens/Pipelines/Vision/Services/RealtimeScreenTextPipeline.swift`
  - Add a `ScreenTextEncounterMemory`.
  - Publish `recentEncounters`.
  - Ingest every readable snapshot before duplicate snapshot persistence checks.
  - Clear encounter memory on recording start and cache clear.

- Modify `falsoai-lens/ContentView.swift`
  - Add a "Last 5 Minutes Screen Text" section.
  - Show unique text lines, first/last seen times, and seen counts.
  - Add copy support for the whole five-minute encounter text.

- Build verification only:
  - The project currently has no test target, so use focused `#if DEBUG` smoke checks for pure logic and the required `xcodebuild` build.

---

### Task 1: Add Screen Text Encounter Models

**Files:**

- Create: `falsoai-lens/Pipelines/Vision/Models/ScreenTextEncounter.swift`

- [ ] **Step 1: Create the encounter model file**

Create `falsoai-lens/Pipelines/Vision/Models/ScreenTextEncounter.swift`:

```swift
import CoreGraphics
import Foundation

struct ScreenTextEncounter: Identifiable, Equatable, Sendable {
    var id: String { normalizedTextHash }

    let text: String
    let normalizedTextHash: String
    let firstSeenAt: Date
    let lastSeenAt: Date
    let seenCount: Int
    let latestSource: ScreenTextEncounterSource
}

struct ScreenTextEncounterSource: Equatable, Sendable {
    let displayID: UInt32
    let displayIndex: Int
    let bounds: CGRect
}

struct ScreenTextEncounterSummary: Equatable, Sendable {
    let totalEncounterCount: Int
    let newEncounterCount: Int
    let updatedEncounterCount: Int
    let prunedEncounterCount: Int
}
```

- [ ] **Step 2: Typecheck the model**

Run:

```bash
xcrun swiftc falsoai-lens/Pipelines/Vision/Models/ScreenTextEncounter.swift -typecheck
```

Expected: no output and exit code `0`.

---

### Task 2: Add Rolling Encounter Memory

**Files:**

- Create: `falsoai-lens/Pipelines/Vision/Services/ScreenTextEncounterMemory.swift`

- [ ] **Step 1: Create the memory actor**

Create `falsoai-lens/Pipelines/Vision/Services/ScreenTextEncounterMemory.swift`:

```swift
import CoreGraphics
import Foundation

actor ScreenTextEncounterMemory {
    private struct TextUnit: Sendable {
        let text: String
        let normalizedTextHash: String
        let source: ScreenTextEncounterSource
    }

    private let windowSeconds: TimeInterval
    private let maxEncounters: Int
    private var encountersByHash: [String: ScreenTextEncounter] = [:]

    init(
        windowSeconds: TimeInterval = 5 * 60,
        maxEncounters: Int = 1_500
    ) {
        self.windowSeconds = max(1, windowSeconds)
        self.maxEncounters = max(1, maxEncounters)
    }

    func ingest(_ snapshot: RealtimeScreenTextSnapshot) -> ScreenTextEncounterSummary {
        let prunedCount = prune(referenceDate: snapshot.capturedAt)
        var newCount = 0
        var updatedCount = 0

        for unit in textUnits(from: snapshot) {
            if let existing = encountersByHash[unit.normalizedTextHash] {
                encountersByHash[unit.normalizedTextHash] = ScreenTextEncounter(
                    text: existing.text,
                    normalizedTextHash: existing.normalizedTextHash,
                    firstSeenAt: existing.firstSeenAt,
                    lastSeenAt: snapshot.capturedAt,
                    seenCount: existing.seenCount + 1,
                    latestSource: unit.source
                )
                updatedCount += 1
            } else {
                encountersByHash[unit.normalizedTextHash] = ScreenTextEncounter(
                    text: unit.text,
                    normalizedTextHash: unit.normalizedTextHash,
                    firstSeenAt: snapshot.capturedAt,
                    lastSeenAt: snapshot.capturedAt,
                    seenCount: 1,
                    latestSource: unit.source
                )
                newCount += 1
            }
        }

        trimToMaxEncounters()

        return ScreenTextEncounterSummary(
            totalEncounterCount: encountersByHash.count,
            newEncounterCount: newCount,
            updatedEncounterCount: updatedCount,
            prunedEncounterCount: prunedCount
        )
    }

    func recentEncounters(referenceDate: Date = Date()) -> [ScreenTextEncounter] {
        _ = prune(referenceDate: referenceDate)
        return encountersByHash.values.sorted { lhs, rhs in
            if lhs.firstSeenAt != rhs.firstSeenAt {
                return lhs.firstSeenAt < rhs.firstSeenAt
            }

            return lhs.text.localizedStandardCompare(rhs.text) == .orderedAscending
        }
    }

    func clear() {
        encountersByHash.removeAll()
    }

    @discardableResult
    private func prune(referenceDate: Date) -> Int {
        let oldestAllowedDate = referenceDate.addingTimeInterval(-windowSeconds)
        let originalCount = encountersByHash.count
        encountersByHash = encountersByHash.filter { _, encounter in
            encounter.lastSeenAt >= oldestAllowedDate
        }
        return originalCount - encountersByHash.count
    }

    private func trimToMaxEncounters() {
        guard encountersByHash.count > maxEncounters else { return }

        let encountersToKeep = encountersByHash.values
            .sorted { lhs, rhs in
                if lhs.lastSeenAt != rhs.lastSeenAt {
                    return lhs.lastSeenAt > rhs.lastSeenAt
                }

                return lhs.firstSeenAt > rhs.firstSeenAt
            }
            .prefix(maxEncounters)

        encountersByHash = Dictionary(
            uniqueKeysWithValues: encountersToKeep.map { ($0.normalizedTextHash, $0) }
        )
    }

    private func textUnits(from snapshot: RealtimeScreenTextSnapshot) -> [TextUnit] {
        snapshot.document.displays.flatMap { display in
            let lineUnits = display.document.lines.compactMap { line in
                textUnit(
                    text: line.text,
                    display: display,
                    bounds: line.boundingBox
                )
            }

            if !lineUnits.isEmpty {
                return lineUnits
            }

            return display.document.observations.compactMap { observation in
                textUnit(
                    text: observation.text,
                    display: display,
                    bounds: observation.boundingBox
                )
            }
        }
    }

    private func textUnit(
        text: String,
        display: DisplayScreenTextDocument,
        bounds: CGRect
    ) -> TextUnit? {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedText = ScreenTextHasher.normalizeText(trimmedText)

        guard normalizedText.count > 1 else {
            return nil
        }

        return TextUnit(
            text: trimmedText,
            normalizedTextHash: ScreenTextHasher.hashNormalizedText(normalizedText),
            source: ScreenTextEncounterSource(
                displayID: display.displayID,
                displayIndex: display.index,
                bounds: bounds
            )
        )
    }
}
```

- [ ] **Step 2: Add DEBUG smoke checks**

Append this to the bottom of `falsoai-lens/Pipelines/Vision/Services/ScreenTextEncounterMemory.swift`:

```swift
#if DEBUG
extension ScreenTextEncounterMemory {
    static func runSmokeChecks() async {
        await verifyDuplicateLinesMerge()
        await verifyOldEncountersPrune()
    }

    private static func verifyDuplicateLinesMerge() async {
        let memory = ScreenTextEncounterMemory(windowSeconds: 300)
        let capturedAt = Date()
        let snapshot = makeSnapshot(
            capturedAt: capturedAt,
            lines: [
                ScreenTextLine(
                    text: "Limited time offer",
                    boundingBox: CGRect(x: 10, y: 10, width: 100, height: 20),
                    observationIDs: []
                ),
                ScreenTextLine(
                    text: " limited   time OFFER ",
                    boundingBox: CGRect(x: 10, y: 40, width: 100, height: 20),
                    observationIDs: []
                )
            ]
        )

        let summary = await memory.ingest(snapshot)
        let encounters = await memory.recentEncounters(referenceDate: capturedAt)

        assert(summary.newEncounterCount == 1, "Expected normalized duplicate lines to create one new encounter")
        assert(summary.updatedEncounterCount == 1, "Expected normalized duplicate lines to update the first encounter")
        assert(encounters.count == 1, "Expected one deduplicated encounter")
        assert(encounters[0].seenCount == 2, "Expected duplicate line seen count to be 2")
    }

    private static func verifyOldEncountersPrune() async {
        let memory = ScreenTextEncounterMemory(windowSeconds: 300)
        let oldDate = Date(timeIntervalSince1970: 1_000)
        let newDate = oldDate.addingTimeInterval(301)

        _ = await memory.ingest(
            makeSnapshot(
                capturedAt: oldDate,
                lines: [
                    ScreenTextLine(
                        text: "Old text",
                        boundingBox: CGRect(x: 0, y: 0, width: 10, height: 10),
                        observationIDs: []
                    )
                ]
            )
        )

        _ = await memory.ingest(
            makeSnapshot(
                capturedAt: newDate,
                lines: [
                    ScreenTextLine(
                        text: "New text",
                        boundingBox: CGRect(x: 0, y: 0, width: 10, height: 10),
                        observationIDs: []
                    )
                ]
            )
        )

        let encounters = await memory.recentEncounters(referenceDate: newDate)
        assert(encounters.map(\.text) == ["New text"], "Expected encounters older than five minutes to be pruned")
    }

    private static func makeSnapshot(
        capturedAt: Date,
        lines: [ScreenTextLine]
    ) -> RealtimeScreenTextSnapshot {
        let displayDocument = DisplayScreenTextDocument(
            displayID: 1,
            index: 0,
            document: ScreenTextDocument(
                capturedAt: capturedAt,
                frameSize: CGSize(width: 200, height: 200),
                frameHash: "frame-\(capturedAt.timeIntervalSince1970)",
                normalizedTextHash: ScreenTextHasher.hashNormalizedText(lines.map(\.text).joined(separator: "\n")),
                layoutHash: "layout-\(capturedAt.timeIntervalSince1970)",
                observations: [],
                lines: lines,
                blocks: [],
                regions: []
            )
        )
        let document = MultiDisplayScreenTextDocument(
            capturedAt: capturedAt,
            displays: [displayDocument]
        )

        return RealtimeScreenTextSnapshot(
            sessionID: UUID(),
            sequenceNumber: 1,
            capturedAt: capturedAt,
            document: document,
            recognizedText: document.recognizedText,
            markdownExport: document.recognizedText,
            compactJSONExport: "{}",
            chunkCount: 1,
            displayCount: 1,
            observationCount: document.observationCount,
            lineCount: document.lineCount,
            blockCount: document.blockCount,
            regionCount: document.regionCount,
            aggregateTextHash: ScreenTextHasher.hashAggregateText(document),
            aggregateLayoutHash: ScreenTextHasher.hashAggregateLayout(document),
            displayFrameHashes: ["frame-\(capturedAt.timeIntervalSince1970)"],
            reusedDisplayCount: 0,
            ocrDisplayCount: 1,
            elapsedSeconds: 0
        )
    }
}
#endif
```

- [ ] **Step 3: Build to verify actor and models compile**

Run:

```bash
xcodebuild -project falsoai-lens.xcodeproj -scheme falsoai-lens -configuration Debug build
```

Expected: build succeeds. If Swift complains about `Dictionary(uniqueKeysWithValues:)` type inference, replace that assignment with:

```swift
var keptEncounters: [String: ScreenTextEncounter] = [:]
for encounter in encountersToKeep {
    keptEncounters[encounter.normalizedTextHash] = encounter
}
encountersByHash = keptEncounters
```

---

### Task 3: Ingest Encounters From The Realtime Pipeline

**Files:**

- Modify: `falsoai-lens/Pipelines/Vision/Services/RealtimeScreenTextPipeline.swift`

- [ ] **Step 1: Add published encounter state**

In `RealtimeScreenTextPipeline`, add this property after `recentSnapshots`:

```swift
@Published private(set) var recentEncounters: [ScreenTextEncounter] = []
```

Add this property near the other private dependencies:

```swift
private let encounterMemory: ScreenTextEncounterMemory
```

- [ ] **Step 2: Update the initializer**

Replace the initializer signature and body with:

```swift
init(
    sampler: RealtimeScreenTextSampler? = nil,
    cache: RealtimeScreenTextCache? = try? RealtimeScreenTextCache.makeDefault(),
    encounterMemory: ScreenTextEncounterMemory = ScreenTextEncounterMemory(),
    sampleIntervalSeconds: TimeInterval = 1
) {
    self.sampler = sampler ?? RealtimeScreenTextSampler()
    self.cache = cache
    self.encounterMemory = encounterMemory
    self.sampleIntervalSeconds = max(1, sampleIntervalSeconds)
    refreshRecentSnapshots()

    #if DEBUG
    Task {
        await ScreenTextEncounterMemory.runSmokeChecks()
    }
    #endif
}
```

- [ ] **Step 3: Clear encounter memory on start**

In `start()`, after resetting `duplicateSamplesSkipped = 0`, add:

```swift
recentEncounters = []
```

Before assigning `captureTask`, add:

```swift
Task {
    await encounterMemory.clear()
}
```

The reset portion should become:

```swift
sessionID = UUID()
sequenceNumber = 0
lastCachedTextHash = nil
lastCachedLayoutHash = nil
samplesCaptured = 0
snapshotsCached = 0
duplicateSamplesSkipped = 0
recentEncounters = []
errorMessage = nil
isRunning = true
statusText = "Realtime screen text is starting..."

Task {
    await encounterMemory.clear()
}
```

- [ ] **Step 4: Clear encounter memory when clearing the screen-text cache**

In `clearCache()`, after `recentSnapshots = []`, add:

```swift
await encounterMemory.clear()
recentEncounters = []
```

The successful clear block should become:

```swift
try await cache.clearAll()
recentSnapshots = []
await encounterMemory.clear()
recentEncounters = []
snapshotsCached = 0
duplicateSamplesSkipped = 0
statusText = isRunning
    ? "Realtime screen text cache cleared; recording continues."
    : "Realtime screen text cache cleared."
```

- [ ] **Step 5: Add a helper for encounter ingestion**

Add this private method before `shouldCache(_:)`:

```swift
private func ingestEncounters(from snapshot: RealtimeScreenTextSnapshot) async -> ScreenTextEncounterSummary {
    let summary = await encounterMemory.ingest(snapshot)
    recentEncounters = await encounterMemory.recentEncounters(referenceDate: snapshot.capturedAt)
    return summary
}
```

- [ ] **Step 6: Ingest readable snapshots before duplicate persistence checks**

In `captureOneSample()`, find:

```swift
guard snapshot.hasReadableText else {
    statusText = "Screen sample \(sequenceNumber) had no readable text."
    return
}

guard try await shouldCache(snapshot) else {
    duplicateSamplesSkipped += 1
    statusText = "Screen text already cached; skipped duplicate sample \(sequenceNumber)."
    return
}
```

Replace it with:

```swift
guard snapshot.hasReadableText else {
    recentEncounters = await encounterMemory.recentEncounters(referenceDate: snapshot.capturedAt)
    statusText = "Screen sample \(sequenceNumber) had no readable text."
    return
}

let encounterSummary = await ingestEncounters(from: snapshot)

guard try await shouldCache(snapshot) else {
    duplicateSamplesSkipped += 1
    statusText = "Screen text already cached; \(encounterSummary.totalEncounterCount) unique lines remain in five-minute memory."
    return
}
```

- [ ] **Step 7: Update the successful cache status text**

In `captureOneSample()`, replace:

```swift
statusText = "Cached all-screen sample \(sequenceNumber) with \(snapshot.recognizedText.count) characters."
```

with:

```swift
statusText = "Cached all-screen sample \(sequenceNumber); \(encounterSummary.totalEncounterCount) unique lines in five-minute memory."
```

- [ ] **Step 8: Build**

Run:

```bash
xcodebuild -project falsoai-lens.xcodeproj -scheme falsoai-lens -configuration Debug build
```

Expected: build succeeds.

---

### Task 4: Add The Last Five Minutes UI

**Files:**

- Modify: `falsoai-lens/ContentView.swift`

- [ ] **Step 1: Add the encounter section to the main screen**

Find the existing main layout call:

```swift
realtimeScreenTextPanel
realtimeCachedTextSection
```

Change it to:

```swift
realtimeScreenTextPanel
realtimeEncounteredTextSection
realtimeCachedTextSection
```

- [ ] **Step 2: Add helper text export for encounters**

Add this helper near `screenTextExportText(markdown:chunks:)`:

```swift
private func encounteredTextExport(_ encounters: [ScreenTextEncounter]) -> String {
    encounters
        .map { encounter in
            let firstSeen = encounter.firstSeenAt.formatted(date: .omitted, time: .standard)
            let lastSeen = encounter.lastSeenAt.formatted(date: .omitted, time: .standard)
            let displayLabel = "Display \(encounter.latestSource.displayIndex + 1)"

            return [
                "[\(firstSeen)-\(lastSeen)] \(displayLabel) seen \(encounter.seenCount)x",
                encounter.text
            ].joined(separator: "\n")
        }
        .joined(separator: "\n\n")
}
```

- [ ] **Step 3: Add the five-minute encounter section**

Add this computed view before `realtimeCachedTextSection`:

```swift
private var realtimeEncounteredTextSection: some View {
    let encounters = realtimeScreenText.recentEncounters
    let exportText = encounteredTextExport(encounters)

    return VStack(alignment: .leading, spacing: 10) {
        HStack {
            Text("Last 5 Minutes Screen Text")
                .font(.headline)
            Spacer()
            Text("\(encounters.count) unique")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button {
                copyToPasteboard(exportText)
            } label: {
                Label("Copy", systemImage: "doc.on.doc")
            }
            .disabled(exportText.isEmpty)
        }

        ScrollView {
            if encounters.isEmpty {
                Text("No screen text encountered yet.")
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            } else {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(encounters) { encounter in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 10) {
                                Label(
                                    "\(encounter.firstSeenAt.formatted(date: .omitted, time: .standard))-\(encounter.lastSeenAt.formatted(date: .omitted, time: .standard))",
                                    systemImage: "clock"
                                )
                                Label("Display \(encounter.latestSource.displayIndex + 1)", systemImage: "display")
                                Label("\(encounter.seenCount)x", systemImage: "repeat")
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)

                            Text(encounter.text)
                                .font(.system(.body, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(.vertical, 4)
                    }
                }
                .padding(10)
            }
        }
        .frame(minHeight: 220, maxHeight: 360)
        .background(Color(nsColor: .textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
    .frame(maxWidth: .infinity, alignment: .topLeading)
    .padding()
    .background(.thinMaterial)
    .clipShape(RoundedRectangle(cornerRadius: 8))
}
```

- [ ] **Step 4: Build**

Run:

```bash
xcodebuild -project falsoai-lens.xcodeproj -scheme falsoai-lens -configuration Debug build
```

Expected: build succeeds.

---

### Task 5: Manual Verification

**Files:**

- No file changes.

- [ ] **Step 1: Build the app**

Run:

```bash
xcodebuild -project falsoai-lens.xcodeproj -scheme falsoai-lens -configuration Debug build
```

Expected: build succeeds.

- [ ] **Step 2: Run in Xcode**

Open:

```bash
open falsoai-lens.xcodeproj
```

Run the `falsoai-lens` scheme from Xcode.

Expected: the app launches and the "Realtime Screen Text" panel is visible.

- [ ] **Step 3: Start realtime screen text**

Click `Start` in the "Realtime Screen Text" panel.

Expected:

- The status changes to `Recording`.
- The sample count increases once per second.
- The "Last 5 Minutes Screen Text" section begins filling with unique text lines.

- [ ] **Step 4: Verify duplicate removal**

Keep the same screen visible for at least five samples.

Expected:

- The "Last 5 Minutes Screen Text" section does not repeat identical lines.
- Repeated lines show a higher `seenCount` such as `2x`, `3x`, or more.
- The snapshot duplicate counter may increase independently; that is expected because snapshot persistence dedupe and line encounter dedupe are separate layers.

- [ ] **Step 5: Verify new text appears**

Scroll a page, switch tabs, or open a document with new visible text.

Expected:

- Newly visible lines are appended to the "Last 5 Minutes Screen Text" section.
- Previously seen lines remain visible if they were last seen within the five-minute window.

- [ ] **Step 6: Verify five-minute pruning**

Leave recording active for more than five minutes while changing visible text.

Expected:

- Lines that have not been seen for more than five minutes disappear from the section.
- Lines that remain visible continue to update their last-seen time and stay in the list.

- [ ] **Step 7: Verify privacy behavior**

Stop recording and then start recording again.

Expected:

- The "Last 5 Minutes Screen Text" section clears at the beginning of the new recording session.
- Durable cached snapshots still appear in "Realtime Cached Text" unless `Clear Cache` is used.

---

## Self-Review Notes

- Spec coverage: the plan captures screen text for five minutes, removes duplicates, preserves all unique text encountered during that window, and surfaces it in the UI.
- Persistence: encounter memory is deliberately in-memory only; the existing GRDB snapshot cache remains separate.
- Deduplication: line-level normalized text hash dedupe is implemented in `ScreenTextEncounterMemory`; snapshot dedupe remains in `RealtimeScreenTextPipeline`.
- Verification: because the project has no test target, this plan uses DEBUG smoke checks plus the required app build and manual UI verification.
