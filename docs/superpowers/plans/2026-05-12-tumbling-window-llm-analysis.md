# Tumbling-Window Screen Text LLM Analysis Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Every five minutes of an active recording session, seal the rolling encounter memory into a window, hand it to a pluggable analyzer (a stub for now, real LLM later), persist the resulting summary, and surface it in the UI.

**Architecture:** Treat `ScreenTextEncounterMemory` as the authoritative 5-minute store. Add a tiny pure-state `ScreenTextWindowTracker` to `RealtimeScreenTextPipeline` that detects when ≥5 min of recording have elapsed since the last seal, snapshots encounters, clears the memory, builds a `ScreenTextWindow`, and dispatches it to a `ScreenTextWindowAnalyzing` actor. The default analyzer is `StubScreenTextWindowAnalyzer` (deterministic markdown digest); swapping in a real LLM later only requires a new conformer. Analyses are persisted to a new GRDB store (`ScreenTextWindowAnalysisStorage`) separate from the snapshot cache, and rendered in `ContentView`.

**Tech Stack:** Swift 5, SwiftUI, GRDB (already a dependency), Combine, OSLog. macOS 26.2. No test target exists; verification follows the project's existing `#if DEBUG runSmokeChecks` convention plus `xcodebuild build` and a short-window manual run.

---

## Scope and Non-Goals

- **In scope:** Window detection, sealing, encounter snapshot + clear, stub analyzer, prompt builder, persistence, UI surface.
- **Out of scope (followups):** Replacing the stub with a real LLM provider; demoting / pruning `RealtimeScreenTextCache` (it currently saves per-tick rows forever — flagged in code review but a separate plan); stripping the per-tick `markdownExport`/`compactJSONExport`/`chunkCount` fields from `RealtimeScreenTextSnapshot` and the cache schema (also a separate plan — it touches a migration and is independent of this work).

## File Structure

**Create:**
- `falsoai-lens/Pipelines/Vision/Models/ScreenTextWindow.swift` — value type for a sealed window
- `falsoai-lens/Pipelines/Vision/Models/ScreenTextWindowInterval.swift` — `(startedAt, endedAt)` value used by the tracker
- `falsoai-lens/Pipelines/Vision/Models/ScreenTextWindowAnalysis.swift` — analyzer output value type
- `falsoai-lens/Pipelines/Vision/Services/ScreenTextWindowTracker.swift` — pure mutating struct that knows when to seal
- `falsoai-lens/Pipelines/Vision/Services/ScreenTextWindowAnalyzing.swift` — `Sendable` protocol
- `falsoai-lens/Pipelines/Vision/Services/StubScreenTextWindowAnalyzer.swift` — default conformer
- `falsoai-lens/Data/ScreenTextWindowAnalyses/ScreenTextWindowAnalysisRecord.swift`
- `falsoai-lens/Data/ScreenTextWindowAnalyses/ScreenTextWindowAnalysisDatabase.swift`
- `falsoai-lens/Data/ScreenTextWindowAnalyses/ScreenTextWindowAnalysisMigrations.swift`
- `falsoai-lens/Data/ScreenTextWindowAnalyses/ScreenTextWindowAnalysisStorage.swift`

**Modify:**
- `falsoai-lens/Pipelines/Vision/Services/ScreenTextLLMPreparationService.swift` — add `prepare(_ window: ScreenTextWindow) -> String`
- `falsoai-lens/Pipelines/Vision/Services/RealtimeScreenTextPipeline.swift` — own the tracker, run the seal check inside `captureOneSample`, dispatch analyzer, persist result
- `falsoai-lens/ContentView.swift` — add a "5-Minute Window Analyses" panel

**Files left untouched:** `RealtimeScreenTextCache*`, `ScreenTextEncounterMemory.swift` (its API is sufficient), `OCRService`, `ScreenCaptureService`, audio pipelines.

## Verification Convention (codebase-specific)

This project has no XCTest/Swift Testing target ([CLAUDE.md](../../../CLAUDE.md)). The convention is `#if DEBUG static func runSmokeChecks() async` invoked from a `Task` inside the relevant init (see [ScreenTextEncounterMemory.swift:153](../../../falsoai-lens/Pipelines/Vision/Services/ScreenTextEncounterMemory.swift#L153) and the call site at [RealtimeScreenTextPipeline.swift:44](../../../falsoai-lens/Pipelines/Vision/Services/RealtimeScreenTextPipeline.swift#L44)). We follow that pattern: each new component ships with a `runSmokeChecks` whose `assert(...)` calls trap on failure.

**For each task:**
1. Write the failing assertions first (smoke check that compiles but would `assert` if implementation is wrong).
2. Run `xcodebuild ... build` to confirm compile.
3. Implement the type.
4. Run `xcodebuild ... build` to confirm both compile and (since `runSmokeChecks` is wired into a DEBUG init) the assertions hold the moment the app initializes the pipeline. Engineer may also briefly launch the app to see the smoke checks run.
5. Commit.

The `xcodebuild` command used everywhere is:

```bash
xcodebuild -project falsoai-lens.xcodeproj -scheme falsoai-lens -configuration Debug build
```

---

## Task 1: `ScreenTextWindowTracker` and `ScreenTextWindowInterval`

A pure mutating struct that pins a `windowStartedAt` and reports a sealed `(start, end)` interval when ≥`windowSeconds` have elapsed. No timers. The pipeline calls `sealIfElapsed` once per 1 s sample tick.

**Files:**
- Create: `falsoai-lens/Pipelines/Vision/Models/ScreenTextWindowInterval.swift`
- Create: `falsoai-lens/Pipelines/Vision/Services/ScreenTextWindowTracker.swift`

- [ ] **Step 1: Create the interval value type**

Create `falsoai-lens/Pipelines/Vision/Models/ScreenTextWindowInterval.swift`:

```swift
import Foundation

struct ScreenTextWindowInterval: Equatable, Sendable {
    let startedAt: Date
    let endedAt: Date

    var durationSeconds: TimeInterval {
        endedAt.timeIntervalSince(startedAt)
    }
}
```

- [ ] **Step 2: Create the tracker with smoke checks first**

Create `falsoai-lens/Pipelines/Vision/Services/ScreenTextWindowTracker.swift` with the smoke-check assertions in place but the body of `start`, `sealIfElapsed`, `stop` empty (`fatalError("unimplemented")`):

```swift
import Foundation

struct ScreenTextWindowTracker: Sendable {
    let windowSeconds: TimeInterval
    private(set) var currentWindowStartedAt: Date?

    init(windowSeconds: TimeInterval = 5 * 60) {
        self.windowSeconds = max(1, windowSeconds)
    }

    mutating func start(referenceDate: Date) {
        fatalError("unimplemented")
    }

    mutating func sealIfElapsed(referenceDate: Date) -> ScreenTextWindowInterval? {
        fatalError("unimplemented")
    }

    mutating func stop() {
        fatalError("unimplemented")
    }
}

#if DEBUG
extension ScreenTextWindowTracker {
    static func runSmokeChecks() {
        verifyDoesNotSealBeforeWindowElapses()
        verifySealsExactlyAtWindowBoundary()
        verifySealsAndContinuesIntoNextWindow()
        verifyStopClearsState()
        verifyDoesNotSealWithoutStart()
    }

    private static func verifyDoesNotSealBeforeWindowElapses() {
        var tracker = ScreenTextWindowTracker(windowSeconds: 60)
        let t0 = Date(timeIntervalSince1970: 1_000)
        tracker.start(referenceDate: t0)
        let result = tracker.sealIfElapsed(referenceDate: t0.addingTimeInterval(59))
        assert(result == nil, "Tracker sealed before windowSeconds elapsed")
        assert(tracker.currentWindowStartedAt == t0, "Tracker dropped its anchor without sealing")
    }

    private static func verifySealsExactlyAtWindowBoundary() {
        var tracker = ScreenTextWindowTracker(windowSeconds: 60)
        let t0 = Date(timeIntervalSince1970: 2_000)
        tracker.start(referenceDate: t0)
        let result = tracker.sealIfElapsed(referenceDate: t0.addingTimeInterval(60))
        assert(result == ScreenTextWindowInterval(startedAt: t0, endedAt: t0.addingTimeInterval(60)),
               "Tracker did not seal at the window boundary")
        assert(tracker.currentWindowStartedAt == t0.addingTimeInterval(60),
               "Tracker did not reset its anchor to the seal time")
    }

    private static func verifySealsAndContinuesIntoNextWindow() {
        var tracker = ScreenTextWindowTracker(windowSeconds: 60)
        let t0 = Date(timeIntervalSince1970: 3_000)
        tracker.start(referenceDate: t0)
        _ = tracker.sealIfElapsed(referenceDate: t0.addingTimeInterval(60))
        let secondResult = tracker.sealIfElapsed(referenceDate: t0.addingTimeInterval(119))
        assert(secondResult == nil, "Tracker sealed second window before its boundary")

        let thirdResult = tracker.sealIfElapsed(referenceDate: t0.addingTimeInterval(120))
        assert(thirdResult == ScreenTextWindowInterval(
                startedAt: t0.addingTimeInterval(60),
                endedAt: t0.addingTimeInterval(120)),
               "Tracker did not seal the second window correctly")
    }

    private static func verifyStopClearsState() {
        var tracker = ScreenTextWindowTracker(windowSeconds: 60)
        tracker.start(referenceDate: Date())
        tracker.stop()
        assert(tracker.currentWindowStartedAt == nil, "Tracker.stop did not clear state")
        let result = tracker.sealIfElapsed(referenceDate: Date().addingTimeInterval(120))
        assert(result == nil, "Tracker sealed after stop")
    }

    private static func verifyDoesNotSealWithoutStart() {
        var tracker = ScreenTextWindowTracker(windowSeconds: 60)
        let result = tracker.sealIfElapsed(referenceDate: Date())
        assert(result == nil, "Tracker sealed without ever starting")
    }
}
#endif
```

- [ ] **Step 3: Run the build to confirm compile**

Run:

```bash
xcodebuild -project falsoai-lens.xcodeproj -scheme falsoai-lens -configuration Debug build 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **` (no test runs yet because `runSmokeChecks` is not called from anywhere).

- [ ] **Step 4: Implement the tracker body**

Replace the three `fatalError("unimplemented")` bodies in `ScreenTextWindowTracker.swift`:

```swift
mutating func start(referenceDate: Date) {
    currentWindowStartedAt = referenceDate
}

mutating func sealIfElapsed(referenceDate: Date) -> ScreenTextWindowInterval? {
    guard let started = currentWindowStartedAt else { return nil }
    guard referenceDate.timeIntervalSince(started) >= windowSeconds else { return nil }

    let interval = ScreenTextWindowInterval(startedAt: started, endedAt: referenceDate)
    currentWindowStartedAt = referenceDate
    return interval
}

mutating func stop() {
    currentWindowStartedAt = nil
}
```

- [ ] **Step 5: Wire the tracker smoke check into the pipeline DEBUG block**

Modify `falsoai-lens/Pipelines/Vision/Services/RealtimeScreenTextPipeline.swift`. Find the existing DEBUG block (lines 44–48):

```swift
#if DEBUG
Task {
    await ScreenTextEncounterMemory.runSmokeChecks()
}
#endif
```

Replace with:

```swift
#if DEBUG
Task {
    await ScreenTextEncounterMemory.runSmokeChecks()
    ScreenTextWindowTracker.runSmokeChecks()
}
#endif
```

- [ ] **Step 6: Build to run smoke checks at app launch**

Run:

```bash
xcodebuild -project falsoai-lens.xcodeproj -scheme falsoai-lens -configuration Debug build 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **`. Open the app once (or just trust the asserts: any failure traps the process; a successful build + launch with no crash = pass).

- [ ] **Step 7: Commit**

```bash
git add falsoai-lens/Pipelines/Vision/Models/ScreenTextWindowInterval.swift \
        falsoai-lens/Pipelines/Vision/Services/ScreenTextWindowTracker.swift \
        falsoai-lens/Pipelines/Vision/Services/RealtimeScreenTextPipeline.swift
git commit -m "$(cat <<'EOF'
feat(vision): add ScreenTextWindowTracker for tumbling 5-min windows

Pure mutating value type that pins a window start and reports a sealed
(start, end) interval when windowSeconds have elapsed. No timers; the
pipeline calls sealIfElapsed once per sample tick. DEBUG smoke checks
cover the seal boundary, multiple windows, stop semantics, and the
no-start guard.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: `ScreenTextWindow`, `ScreenTextWindowAnalysis`, `ScreenTextWindowAnalyzing`

Three small value/protocol files. No behavior, just shapes; smoke checks limited to identity helpers.

**Files:**
- Create: `falsoai-lens/Pipelines/Vision/Models/ScreenTextWindow.swift`
- Create: `falsoai-lens/Pipelines/Vision/Models/ScreenTextWindowAnalysis.swift`
- Create: `falsoai-lens/Pipelines/Vision/Services/ScreenTextWindowAnalyzing.swift`

- [ ] **Step 1: Create `ScreenTextWindow.swift`**

```swift
import Foundation

struct ScreenTextWindow: Identifiable, Sendable, Equatable {
    let id: UUID
    let sessionID: UUID
    let sequenceNumber: Int
    let startedAt: Date
    let endedAt: Date
    let encounters: [ScreenTextEncounter]

    var durationSeconds: TimeInterval { endedAt.timeIntervalSince(startedAt) }
    var encounterCount: Int { encounters.count }
    var isEmpty: Bool { encounters.isEmpty }
}
```

- [ ] **Step 2: Create `ScreenTextWindowAnalysis.swift`**

```swift
import Foundation

struct ScreenTextWindowAnalysis: Identifiable, Sendable, Equatable {
    let id: UUID
    let windowID: UUID
    let sessionID: UUID
    let sequenceNumber: Int
    let windowStartedAt: Date
    let windowEndedAt: Date
    let generatedAt: Date
    let analyzerID: String
    let summaryMarkdown: String
    let encounterCount: Int
    let latencySeconds: Double
    let errorMessage: String?
}
```

- [ ] **Step 3: Create `ScreenTextWindowAnalyzing.swift`**

```swift
import Foundation

protocol ScreenTextWindowAnalyzing: Sendable {
    var analyzerID: String { get }
    func analyze(_ window: ScreenTextWindow) async throws -> ScreenTextWindowAnalysis
}
```

- [ ] **Step 4: Build**

```bash
xcodebuild -project falsoai-lens.xcodeproj -scheme falsoai-lens -configuration Debug build 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
git add falsoai-lens/Pipelines/Vision/Models/ScreenTextWindow.swift \
        falsoai-lens/Pipelines/Vision/Models/ScreenTextWindowAnalysis.swift \
        falsoai-lens/Pipelines/Vision/Services/ScreenTextWindowAnalyzing.swift
git commit -m "$(cat <<'EOF'
feat(vision): add ScreenTextWindow models and analyzer protocol

Introduce the value types passed across the new flush boundary:
ScreenTextWindow (a sealed 5-min capture of unique encounters),
ScreenTextWindowAnalysis (analyzer output), and the
ScreenTextWindowAnalyzing protocol that lets the pipeline plug in a
stub today and a real LLM later.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: Add `prepare(_ window: ScreenTextWindow)` to `ScreenTextLLMPreparationService`

Builds the markdown prompt the analyzer will send to whatever model. Pure formatting, no model calls.

**Files:**
- Modify: `falsoai-lens/Pipelines/Vision/Services/ScreenTextLLMPreparationService.swift`

- [ ] **Step 1: Add a smoke check to the existing service file (failing first)**

At the bottom of `falsoai-lens/Pipelines/Vision/Services/ScreenTextLLMPreparationService.swift`, append:

```swift
#if DEBUG
extension ScreenTextLLMPreparationService {
    static func runSmokeChecks() {
        verifyEmptyWindowProducesEmptyEncountersSection()
        verifyWindowFormatsEncountersChronologically()
    }

    private static func verifyEmptyWindowProducesEmptyEncountersSection() {
        let service = ScreenTextLLMPreparationService()
        let window = ScreenTextWindow(
            id: UUID(),
            sessionID: UUID(),
            sequenceNumber: 1,
            startedAt: Date(timeIntervalSince1970: 0),
            endedAt: Date(timeIntervalSince1970: 300),
            encounters: []
        )
        let prompt = service.prepare(window)
        assert(prompt.contains("encounterCount: 0"),
               "Empty window prompt missing encounterCount: 0")
        assert(prompt.contains("_No readable text was captured during this window._"),
               "Empty window prompt missing empty-marker")
    }

    private static func verifyWindowFormatsEncountersChronologically() {
        let service = ScreenTextLLMPreparationService()
        let earlier = Date(timeIntervalSince1970: 100)
        let later = Date(timeIntervalSince1970: 200)
        let window = ScreenTextWindow(
            id: UUID(),
            sessionID: UUID(),
            sequenceNumber: 2,
            startedAt: Date(timeIntervalSince1970: 0),
            endedAt: Date(timeIntervalSince1970: 300),
            encounters: [
                ScreenTextEncounter(
                    text: "later line",
                    normalizedTextHash: "h-later",
                    firstSeenAt: later,
                    lastSeenAt: later,
                    seenCount: 1,
                    latestSource: ScreenTextEncounterSource(displayID: 1, displayIndex: 0, bounds: .zero)
                ),
                ScreenTextEncounter(
                    text: "earlier line",
                    normalizedTextHash: "h-earlier",
                    firstSeenAt: earlier,
                    lastSeenAt: earlier,
                    seenCount: 1,
                    latestSource: ScreenTextEncounterSource(displayID: 1, displayIndex: 0, bounds: .zero)
                )
            ]
        )
        let prompt = service.prepare(window)
        guard let earlierIndex = prompt.range(of: "earlier line"),
              let laterIndex = prompt.range(of: "later line") else {
            assertionFailure("Prompt missing one of the encounter texts")
            return
        }
        assert(earlierIndex.lowerBound < laterIndex.lowerBound,
               "Encounters not sorted chronologically in prompt")
    }
}
#endif
```

- [ ] **Step 2: Implement `prepare(_ window:)` on the service**

Inside the `struct ScreenTextLLMPreparationService { ... }` block, add a new method (after the existing `prepare(_ snapshot:)` method):

```swift
func prepare(_ window: ScreenTextWindow) -> String {
    var output: [String] = []
    output.append("# Screen Text Window")
    output.append("")
    output.append("- sessionID: \(window.sessionID.uuidString)")
    output.append("- sequence: \(window.sequenceNumber)")
    output.append("- startedAt: \(window.startedAt.ISO8601Format())")
    output.append("- endedAt: \(window.endedAt.ISO8601Format())")
    output.append("- durationSeconds: \(Int(window.durationSeconds.rounded()))")
    output.append("- encounterCount: \(window.encounterCount)")
    output.append("")
    output.append("## Encounters (chronological)")
    output.append("")

    if window.encounters.isEmpty {
        output.append("_No readable text was captured during this window._")
        return output.joined(separator: "\n")
    }

    let sortedEncounters = window.encounters.sorted { lhs, rhs in
        if lhs.firstSeenAt != rhs.firstSeenAt {
            return lhs.firstSeenAt < rhs.firstSeenAt
        }
        return lhs.text.localizedStandardCompare(rhs.text) == .orderedAscending
    }

    for encounter in sortedEncounters {
        let firstSeen = encounter.firstSeenAt.formatted(date: .omitted, time: .standard)
        let lastSeen = encounter.lastSeenAt.formatted(date: .omitted, time: .standard)
        let line = "- [\(firstSeen) → \(lastSeen) ×\(encounter.seenCount), display \(encounter.latestSource.displayIndex)] \(encounter.text)"
        output.append(line)
    }

    return output.joined(separator: "\n")
}
```

- [ ] **Step 3: Wire the smoke check into the pipeline DEBUG block**

Modify `falsoai-lens/Pipelines/Vision/Services/RealtimeScreenTextPipeline.swift` DEBUG block (currently after Task 1):

```swift
#if DEBUG
Task {
    await ScreenTextEncounterMemory.runSmokeChecks()
    ScreenTextWindowTracker.runSmokeChecks()
    ScreenTextLLMPreparationService.runSmokeChecks()
}
#endif
```

- [ ] **Step 4: Build**

```bash
xcodebuild -project falsoai-lens.xcodeproj -scheme falsoai-lens -configuration Debug build 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
git add falsoai-lens/Pipelines/Vision/Services/ScreenTextLLMPreparationService.swift \
        falsoai-lens/Pipelines/Vision/Services/RealtimeScreenTextPipeline.swift
git commit -m "$(cat <<'EOF'
feat(vision): add prepare(_ window:) prompt builder for window analyses

Render a sealed ScreenTextWindow as the markdown prompt an analyzer
sends to the LLM: window metadata header followed by a chronologically
sorted list of unique encounters with first-seen / last-seen times,
seen counts, and source display index. DEBUG smoke checks cover the
empty-window path and chronological ordering.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 4: `StubScreenTextWindowAnalyzer`

Default analyzer used until a real LLM provider is picked. Deterministic markdown digest of the window. Useful for verifying plumbing end-to-end without leaving the device.

**Files:**
- Create: `falsoai-lens/Pipelines/Vision/Services/StubScreenTextWindowAnalyzer.swift`

- [ ] **Step 1: Write the smoke checks first (asserting behavior we don't have yet)**

Create `falsoai-lens/Pipelines/Vision/Services/StubScreenTextWindowAnalyzer.swift`:

```swift
import Foundation

struct StubScreenTextWindowAnalyzer: ScreenTextWindowAnalyzing {
    let analyzerID = "stub-summary-1"
    private let promptBuilder: ScreenTextLLMPreparationService

    init(promptBuilder: ScreenTextLLMPreparationService = ScreenTextLLMPreparationService()) {
        self.promptBuilder = promptBuilder
    }

    func analyze(_ window: ScreenTextWindow) async throws -> ScreenTextWindowAnalysis {
        fatalError("unimplemented")
    }
}

#if DEBUG
extension StubScreenTextWindowAnalyzer {
    static func runSmokeChecks() async {
        await verifyAnalyzerProducesAnalysisCarryingWindowIdentity()
        await verifyAnalyzerSummaryMentionsEncounterCount()
        await verifyEmptyWindowStillProducesAnalysis()
    }

    private static func sampleWindow(encounters: [ScreenTextEncounter] = []) -> ScreenTextWindow {
        ScreenTextWindow(
            id: UUID(),
            sessionID: UUID(),
            sequenceNumber: 7,
            startedAt: Date(timeIntervalSince1970: 0),
            endedAt: Date(timeIntervalSince1970: 300),
            encounters: encounters
        )
    }

    private static func sampleEncounter(text: String) -> ScreenTextEncounter {
        ScreenTextEncounter(
            text: text,
            normalizedTextHash: "hash-\(text)",
            firstSeenAt: Date(timeIntervalSince1970: 10),
            lastSeenAt: Date(timeIntervalSince1970: 20),
            seenCount: 3,
            latestSource: ScreenTextEncounterSource(displayID: 1, displayIndex: 0, bounds: .zero)
        )
    }

    private static func verifyAnalyzerProducesAnalysisCarryingWindowIdentity() async {
        let analyzer = StubScreenTextWindowAnalyzer()
        let window = sampleWindow(encounters: [sampleEncounter(text: "hello")])
        let analysis = try? await analyzer.analyze(window)
        assert(analysis != nil, "Stub analyzer threw")
        assert(analysis?.windowID == window.id, "Analysis windowID does not match window")
        assert(analysis?.sessionID == window.sessionID, "Analysis sessionID does not match window")
        assert(analysis?.sequenceNumber == window.sequenceNumber, "Analysis sequenceNumber mismatch")
        assert(analysis?.analyzerID == "stub-summary-1", "Analysis analyzerID is not the stub id")
        assert(analysis?.windowStartedAt == window.startedAt, "Analysis windowStartedAt mismatch")
        assert(analysis?.windowEndedAt == window.endedAt, "Analysis windowEndedAt mismatch")
        assert(analysis?.errorMessage == nil, "Stub analyzer set an error message on success")
    }

    private static func verifyAnalyzerSummaryMentionsEncounterCount() async {
        let analyzer = StubScreenTextWindowAnalyzer()
        let window = sampleWindow(encounters: [
            sampleEncounter(text: "alpha"),
            sampleEncounter(text: "beta")
        ])
        let analysis = try? await analyzer.analyze(window)
        let summary = analysis?.summaryMarkdown ?? ""
        assert(summary.contains("Unique lines: 2"),
               "Stub summary missing encounter count line")
        assert(summary.contains("alpha") && summary.contains("beta"),
               "Stub summary missing encounter texts")
    }

    private static func verifyEmptyWindowStillProducesAnalysis() async {
        let analyzer = StubScreenTextWindowAnalyzer()
        let window = sampleWindow()
        let analysis = try? await analyzer.analyze(window)
        assert(analysis != nil, "Stub analyzer threw on empty window")
        assert(analysis?.encounterCount == 0, "Stub analysis encounterCount mismatch on empty window")
        assert(analysis?.summaryMarkdown.contains("_(none)_") == true,
               "Stub summary did not mark empty encounters")
    }
}
#endif
```

- [ ] **Step 2: Build to confirm compile**

```bash
xcodebuild -project falsoai-lens.xcodeproj -scheme falsoai-lens -configuration Debug build 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **` (smoke checks not yet wired into init, so they don't run).

- [ ] **Step 3: Implement `analyze`**

Replace the `fatalError("unimplemented")` body in `StubScreenTextWindowAnalyzer.swift` with:

```swift
func analyze(_ window: ScreenTextWindow) async throws -> ScreenTextWindowAnalysis {
    let started = Date()
    let prompt = promptBuilder.prepare(window)
    let summary = makeSummary(window: window, prompt: prompt)
    let elapsed = Date().timeIntervalSince(started)

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

private func makeSummary(window: ScreenTextWindow, prompt: String) -> String {
    let header = """
    ## Stub Window Summary

    - Sequence: \(window.sequenceNumber)
    - Window: \(window.startedAt.formatted()) → \(window.endedAt.formatted())
    - Duration: \(Int(window.durationSeconds.rounded())) s
    - Unique lines: \(window.encounterCount)
    """

    let preview: String
    if window.encounters.isEmpty {
        preview = "_(none)_"
    } else {
        preview = window.encounters
            .sorted { $0.firstSeenAt < $1.firstSeenAt }
            .prefix(10)
            .map { encounter in
                "- [seen \(encounter.seenCount)x] \(encounter.text)"
            }
            .joined(separator: "\n")
    }

    return """
    \(header)

    ### Top encounters (chronological, first 10)
    \(preview)

    ---
    Prompt size: \(prompt.utf8.count) bytes (would be sent to a real LLM here)
    """
}
```

- [ ] **Step 4: Wire smoke check into the pipeline DEBUG block**

Modify `falsoai-lens/Pipelines/Vision/Services/RealtimeScreenTextPipeline.swift` DEBUG block:

```swift
#if DEBUG
Task {
    await ScreenTextEncounterMemory.runSmokeChecks()
    ScreenTextWindowTracker.runSmokeChecks()
    ScreenTextLLMPreparationService.runSmokeChecks()
    await StubScreenTextWindowAnalyzer.runSmokeChecks()
}
#endif
```

- [ ] **Step 5: Build**

```bash
xcodebuild -project falsoai-lens.xcodeproj -scheme falsoai-lens -configuration Debug build 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 6: Commit**

```bash
git add falsoai-lens/Pipelines/Vision/Services/StubScreenTextWindowAnalyzer.swift \
        falsoai-lens/Pipelines/Vision/Services/RealtimeScreenTextPipeline.swift
git commit -m "$(cat <<'EOF'
feat(vision): add StubScreenTextWindowAnalyzer as the default analyzer

Deterministic markdown digest of a sealed window — header with
metadata, first 10 encounters chronologically, prompt size footer. Used
to verify the flush + persistence + UI path end-to-end without
committing to an LLM provider yet. Conforms to ScreenTextWindowAnalyzing
so it can be replaced with a real client later.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 5: Wire window detection and flush into `RealtimeScreenTextPipeline` (no persistence yet)

Pipeline gains: tracker state, analyzer reference, in-flight task tracking, and three new `@Published` properties so the UI can render progress before persistence is wired up.

**Files:**
- Modify: `falsoai-lens/Pipelines/Vision/Services/RealtimeScreenTextPipeline.swift`

- [ ] **Step 1: Add new stored properties and init parameters**

In `RealtimeScreenTextPipeline.swift`, find the `@Published` block (lines 7–17) and the `private` block (lines 18–30). Add these immediately after the existing `@Published` properties:

```swift
@Published private(set) var lastAnalysis: ScreenTextWindowAnalysis?
@Published private(set) var lastAnalysisError: String?
@Published private(set) var windowsCompleted = 0
@Published private(set) var currentWindowStartedAt: Date?
```

And add these after the existing private properties (around line 30):

```swift
private let windowAnalyzer: any ScreenTextWindowAnalyzing
private var windowTracker: ScreenTextWindowTracker
private var windowSequenceNumber = 0
private var windowAnalysisTasks: [Task<Void, Never>] = []
```

Replace the existing `init`:

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
        ScreenTextWindowTracker.runSmokeChecks()
        ScreenTextLLMPreparationService.runSmokeChecks()
        await StubScreenTextWindowAnalyzer.runSmokeChecks()
    }
    #endif
}
```

with:

```swift
init(
    sampler: RealtimeScreenTextSampler? = nil,
    cache: RealtimeScreenTextCache? = try? RealtimeScreenTextCache.makeDefault(),
    encounterMemory: ScreenTextEncounterMemory = ScreenTextEncounterMemory(),
    sampleIntervalSeconds: TimeInterval = 1,
    windowAnalyzer: any ScreenTextWindowAnalyzing = StubScreenTextWindowAnalyzer(),
    windowSeconds: TimeInterval = 5 * 60
) {
    self.sampler = sampler ?? RealtimeScreenTextSampler()
    self.cache = cache
    self.encounterMemory = encounterMemory
    self.sampleIntervalSeconds = max(1, sampleIntervalSeconds)
    self.windowAnalyzer = windowAnalyzer
    self.windowTracker = ScreenTextWindowTracker(windowSeconds: windowSeconds)
    refreshRecentSnapshots()

    #if DEBUG
    Task {
        await ScreenTextEncounterMemory.runSmokeChecks()
        ScreenTextWindowTracker.runSmokeChecks()
        ScreenTextLLMPreparationService.runSmokeChecks()
        await StubScreenTextWindowAnalyzer.runSmokeChecks()
    }
    #endif
}
```

- [ ] **Step 2: Update `start()` and `stop()` to drive the tracker**

Find `start()` (lines 51–70). Add three lines inside, immediately after `errorMessage = nil`:

```swift
windowSequenceNumber = 0
windowsCompleted = 0
lastAnalysis = nil
lastAnalysisError = nil
windowTracker.start(referenceDate: Date())
currentWindowStartedAt = windowTracker.currentWindowStartedAt
```

So the full block reads:

```swift
func start() {
    guard !isRunning else { return }

    sessionID = UUID()
    sequenceNumber = 0
    lastCachedTextHash = nil
    lastCachedLayoutHash = nil
    samplesCaptured = 0
    snapshotsCached = 0
    duplicateSamplesSkipped = 0
    recentEncounters = []
    errorMessage = nil
    windowSequenceNumber = 0
    windowsCompleted = 0
    lastAnalysis = nil
    lastAnalysisError = nil
    windowTracker.start(referenceDate: Date())
    currentWindowStartedAt = windowTracker.currentWindowStartedAt
    isRunning = true
    statusText = "Realtime screen text is starting..."

    captureTask = Task { [weak self] in
        await self?.encounterMemory.clear()
        await self?.runLoop()
    }
}
```

Find `stop()` (lines 72–81) and replace with:

```swift
func stop() {
    captureTask?.cancel()
    captureTask = nil
    windowAnalysisTasks.forEach { $0.cancel() }
    windowAnalysisTasks.removeAll()
    windowTracker.stop()
    currentWindowStartedAt = nil
    isRunning = false
    isSampling = false
    statusText = snapshotsCached > 0
        ? "Realtime screen text stopped after caching \(snapshotsCached) changed snapshots."
        : "Realtime screen text is stopped."
    logger.info("Realtime screen text stopped cachedSnapshots=\(self.snapshotsCached, privacy: .public), duplicateSamplesSkipped=\(self.duplicateSamplesSkipped, privacy: .public), windowsCompleted=\(self.windowsCompleted, privacy: .public)")
}
```

- [ ] **Step 3: Add the flush path**

Inside the class, immediately after `private func ingestEncounters(...)` (currently lines 173–177), add:

```swift
private func sealAndFlushWindow(at referenceDate: Date) async {
    guard let interval = windowTracker.sealIfElapsed(referenceDate: referenceDate) else {
        return
    }

    windowSequenceNumber += 1
    let sequenceNumber = windowSequenceNumber
    let encounters = await encounterMemory.recentEncounters(referenceDate: interval.endedAt)
    await encounterMemory.clear()
    recentEncounters = []

    let window = ScreenTextWindow(
        id: UUID(),
        sessionID: sessionID,
        sequenceNumber: sequenceNumber,
        startedAt: interval.startedAt,
        endedAt: interval.endedAt,
        encounters: encounters
    )

    currentWindowStartedAt = windowTracker.currentWindowStartedAt
    statusText = "Window \(sequenceNumber) sealed (\(encounters.count) lines); analyzing..."
    logger.info("Sealing window sequence=\(sequenceNumber, privacy: .public), encounters=\(encounters.count, privacy: .public)")

    let analyzer = self.windowAnalyzer
    let task = Task { [weak self] in
        guard !Task.isCancelled else { return }
        do {
            let analysis = try await analyzer.analyze(window)
            await self?.handleAnalysisCompleted(analysis)
        } catch {
            await self?.handleAnalysisFailed(error: error, window: window)
        }
    }
    windowAnalysisTasks.append(task)
}

private func handleAnalysisCompleted(_ analysis: ScreenTextWindowAnalysis) {
    lastAnalysis = analysis
    lastAnalysisError = nil
    windowsCompleted += 1
    statusText = "Window \(analysis.sequenceNumber) analyzed (\(analysis.encounterCount) lines, \(String(format: "%.2f", analysis.latencySeconds)) s)."
    logger.info("Window analysis completed sequence=\(analysis.sequenceNumber, privacy: .public), encounters=\(analysis.encounterCount, privacy: .public), latencySeconds=\(analysis.latencySeconds, privacy: .public)")
}

private func handleAnalysisFailed(error: Error, window: ScreenTextWindow) {
    lastAnalysisError = Self.userFacingMessage(for: error)
    statusText = "Window \(window.sequenceNumber) analysis failed."
    logger.error("Window analysis failed sequence=\(window.sequenceNumber, privacy: .public), error=\(String(describing: error), privacy: .public)")
}
```

- [ ] **Step 4: Call the seal at the end of every sample**

Find `captureOneSample()` (lines 132–171). At the very end of the `do` block (after the `try await cache?.save(snapshot)` chunk and before the closing `} catch`), add a single line so the seal runs every tick regardless of whether the snapshot was cached:

Replace the existing `do { ... }` block:

```swift
do {
    let snapshot = try await sampler.sample(
        sessionID: sessionID,
        sequenceNumber: sequenceNumber
    )
    samplesCaptured += 1
    latestSnapshot = snapshot

    guard snapshot.hasReadableText else {
        recentEncounters = await encounterMemory.recentEncounters(referenceDate: snapshot.capturedAt)
        statusText = "Screen sample \(sequenceNumber) had no readable text."
        await sealAndFlushWindow(at: snapshot.capturedAt)
        return
    }

    let encounterSummary = await ingestEncounters(from: snapshot)

    guard try await shouldCache(snapshot) else {
        duplicateSamplesSkipped += 1
        statusText = "Screen text already cached; \(encounterSummary.totalEncounterCount) unique lines remain in five-minute memory."
        await sealAndFlushWindow(at: snapshot.capturedAt)
        return
    }

    try await cache?.save(snapshot)
    lastCachedTextHash = snapshot.aggregateTextHash
    lastCachedLayoutHash = snapshot.aggregateLayoutHash
    snapshotsCached += 1
    refreshRecentSnapshots()
    statusText = "Cached all-screen sample \(sequenceNumber); \(encounterSummary.totalEncounterCount) unique lines in five-minute memory."

    await sealAndFlushWindow(at: snapshot.capturedAt)
} catch {
```

(The only changes are the three new `await sealAndFlushWindow(at: snapshot.capturedAt)` calls — one before each `return` and one after the final cache write.)

- [ ] **Step 5: Update `clearCache()` to also clear the window state**

Find `clearCache()` (lines 98–117). After the existing `await encounterMemory.clear()` line, add:

```swift
windowTracker.stop()
if isRunning {
    windowTracker.start(referenceDate: Date())
    currentWindowStartedAt = windowTracker.currentWindowStartedAt
} else {
    currentWindowStartedAt = nil
}
windowSequenceNumber = 0
windowsCompleted = 0
lastAnalysis = nil
lastAnalysisError = nil
```

So the full block reads:

```swift
func clearCache() {
    guard let cache else { return }

    Task {
        do {
            try await cache.clearAll()
            recentSnapshots = []
            await encounterMemory.clear()
            recentEncounters = []
            windowTracker.stop()
            if isRunning {
                windowTracker.start(referenceDate: Date())
                currentWindowStartedAt = windowTracker.currentWindowStartedAt
            } else {
                currentWindowStartedAt = nil
            }
            windowSequenceNumber = 0
            windowsCompleted = 0
            lastAnalysis = nil
            lastAnalysisError = nil
            snapshotsCached = 0
            duplicateSamplesSkipped = 0
            statusText = isRunning
                ? "Realtime screen text cache cleared; recording continues."
                : "Realtime screen text cache cleared."
        } catch {
            errorMessage = Self.userFacingMessage(for: error)
            logger.error("Realtime screen text cache clear failed: \(String(describing: error), privacy: .public)")
        }
    }
}
```

- [ ] **Step 6: Build**

```bash
xcodebuild -project falsoai-lens.xcodeproj -scheme falsoai-lens -configuration Debug build 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 7: Commit**

```bash
git add falsoai-lens/Pipelines/Vision/Services/RealtimeScreenTextPipeline.swift
git commit -m "$(cat <<'EOF'
feat(vision): seal and analyze 5-minute screen text windows in pipeline

RealtimeScreenTextPipeline now owns a ScreenTextWindowTracker and a
ScreenTextWindowAnalyzing reference (StubScreenTextWindowAnalyzer by
default). After every 1s sample it asks the tracker whether the window
has elapsed; if so it snapshots the rolling encounter memory, clears
it, builds a ScreenTextWindow, and dispatches the analyzer in a tracked
detached Task. Analysis results are exposed via lastAnalysis /
lastAnalysisError / windowsCompleted / currentWindowStartedAt. start(),
stop(), and clearCache() all keep the tracker, in-flight tasks, and
counters consistent with session state.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 6: Add `ScreenTextWindowAnalysisStorage` (GRDB)

Mirror the structure of `RealtimeScreenTextCache`. Single table, one migration, one actor with `save` / `fetchRecent` / `clearAll`.

**Files:**
- Create: `falsoai-lens/Data/ScreenTextWindowAnalyses/ScreenTextWindowAnalysisRecord.swift`
- Create: `falsoai-lens/Data/ScreenTextWindowAnalyses/ScreenTextWindowAnalysisMigrations.swift`
- Create: `falsoai-lens/Data/ScreenTextWindowAnalyses/ScreenTextWindowAnalysisDatabase.swift`
- Create: `falsoai-lens/Data/ScreenTextWindowAnalyses/ScreenTextWindowAnalysisStorage.swift`

- [ ] **Step 1: Create the directory**

```bash
mkdir -p falsoai-lens/Data/ScreenTextWindowAnalyses
```

- [ ] **Step 2: Create the record**

Create `falsoai-lens/Data/ScreenTextWindowAnalyses/ScreenTextWindowAnalysisRecord.swift`:

```swift
import Foundation
import GRDB

struct ScreenTextWindowAnalysisRecord: Codable, FetchableRecord, PersistableRecord, Identifiable, Equatable {
    static let databaseTableName = "screen_text_window_analyses"

    var id: Int64?
    var analysisID: UUID
    var windowID: UUID
    var sessionID: UUID
    var sequenceNumber: Int
    var windowStartedAt: Date
    var windowEndedAt: Date
    var generatedAt: Date
    var analyzerID: String
    var summaryMarkdown: String
    var encounterCount: Int
    var latencySeconds: Double
    var errorMessage: String?
}
```

- [ ] **Step 3: Create the migrations**

Create `falsoai-lens/Data/ScreenTextWindowAnalyses/ScreenTextWindowAnalysisMigrations.swift`:

```swift
import GRDB

enum ScreenTextWindowAnalysisMigrations {
    nonisolated static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("createScreenTextWindowAnalyses") { db in
            try db.create(table: ScreenTextWindowAnalysisRecord.databaseTableName, ifNotExists: true) { table in
                table.autoIncrementedPrimaryKey("id")
                table.column("analysisID", .text).notNull().unique()
                table.column("windowID", .text).notNull()
                table.column("sessionID", .text).notNull()
                table.column("sequenceNumber", .integer).notNull()
                table.column("windowStartedAt", .datetime).notNull()
                table.column("windowEndedAt", .datetime).notNull()
                table.column("generatedAt", .datetime).notNull()
                table.column("analyzerID", .text).notNull()
                table.column("summaryMarkdown", .text).notNull()
                table.column("encounterCount", .integer).notNull()
                table.column("latencySeconds", .double).notNull()
                table.column("errorMessage", .text)
            }

            try db.create(
                index: "screen_text_window_analyses_generatedAt",
                on: ScreenTextWindowAnalysisRecord.databaseTableName,
                columns: ["generatedAt"]
            )
            try db.create(
                index: "screen_text_window_analyses_session_sequence",
                on: ScreenTextWindowAnalysisRecord.databaseTableName,
                columns: ["sessionID", "sequenceNumber"]
            )
        }

        return migrator
    }
}
```

- [ ] **Step 4: Create the database container**

Create `falsoai-lens/Data/ScreenTextWindowAnalyses/ScreenTextWindowAnalysisDatabase.swift`:

```swift
import Foundation
import GRDB

final class ScreenTextWindowAnalysisDatabase {
    let dbQueue: DatabaseQueue

    nonisolated init(databaseURL: URL) throws {
        dbQueue = try DatabaseQueue(path: databaseURL.path)
        try ScreenTextWindowAnalysisMigrations.migrator.migrate(dbQueue)
    }

    nonisolated static func makeDefault() throws -> ScreenTextWindowAnalysisDatabase {
        try ScreenTextWindowAnalysisDatabase(databaseURL: defaultDatabaseURL())
    }

    nonisolated static func makePreview() throws -> ScreenTextWindowAnalysisDatabase {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("FalsoaiLensScreenTextWindowAnalyses-\(UUID().uuidString).sqlite")
        return try ScreenTextWindowAnalysisDatabase(databaseURL: url)
    }

    nonisolated private static func defaultDatabaseURL() throws -> URL {
        let baseURL = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )

        let directoryURL = baseURL.appendingPathComponent("FalsoaiLens", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)

        return directoryURL.appendingPathComponent("ScreenTextWindowAnalyses.sqlite")
    }
}
```

- [ ] **Step 5: Create the storage actor with smoke checks first**

Create `falsoai-lens/Data/ScreenTextWindowAnalyses/ScreenTextWindowAnalysisStorage.swift`:

```swift
import Foundation
import GRDB

actor ScreenTextWindowAnalysisStorage {
    private let database: ScreenTextWindowAnalysisDatabase

    init(database: ScreenTextWindowAnalysisDatabase) {
        self.database = database
    }

    static func makeDefault() throws -> ScreenTextWindowAnalysisStorage {
        try ScreenTextWindowAnalysisStorage(database: .makeDefault())
    }

    static func makePreview() throws -> ScreenTextWindowAnalysisStorage {
        try ScreenTextWindowAnalysisStorage(database: .makePreview())
    }

    @discardableResult
    func save(_ analysis: ScreenTextWindowAnalysis) throws -> ScreenTextWindowAnalysisRecord {
        let record = ScreenTextWindowAnalysisRecord(
            id: nil,
            analysisID: analysis.id,
            windowID: analysis.windowID,
            sessionID: analysis.sessionID,
            sequenceNumber: analysis.sequenceNumber,
            windowStartedAt: analysis.windowStartedAt,
            windowEndedAt: analysis.windowEndedAt,
            generatedAt: analysis.generatedAt,
            analyzerID: analysis.analyzerID,
            summaryMarkdown: analysis.summaryMarkdown,
            encounterCount: analysis.encounterCount,
            latencySeconds: analysis.latencySeconds,
            errorMessage: analysis.errorMessage
        )

        return try database.dbQueue.write { db in
            var mutableRecord = record
            try mutableRecord.insert(db)
            mutableRecord.id = db.lastInsertedRowID
            return mutableRecord
        }
    }

    func fetchRecent(limit: Int = 50) throws -> [ScreenTextWindowAnalysisRecord] {
        try database.dbQueue.read { db in
            try ScreenTextWindowAnalysisRecord.fetchAll(
                db,
                sql: """
                    SELECT *
                    FROM screen_text_window_analyses
                    ORDER BY generatedAt DESC, id DESC
                    LIMIT ?
                    """,
                arguments: [limit]
            )
        }
    }

    func clearAll() throws {
        try database.dbQueue.write { db in
            try db.execute(sql: "DELETE FROM screen_text_window_analyses")
        }
    }
}

#if DEBUG
extension ScreenTextWindowAnalysisStorage {
    static func runSmokeChecks() async {
        await verifySaveAndFetchRoundTrip()
        await verifyClearAllEmptiesTable()
    }

    private static func sampleAnalysis() -> ScreenTextWindowAnalysis {
        ScreenTextWindowAnalysis(
            id: UUID(),
            windowID: UUID(),
            sessionID: UUID(),
            sequenceNumber: 1,
            windowStartedAt: Date(timeIntervalSince1970: 0),
            windowEndedAt: Date(timeIntervalSince1970: 300),
            generatedAt: Date(timeIntervalSince1970: 301),
            analyzerID: "stub-summary-1",
            summaryMarkdown: "Hello",
            encounterCount: 3,
            latencySeconds: 0.42,
            errorMessage: nil
        )
    }

    private static func verifySaveAndFetchRoundTrip() async {
        guard let storage = try? makePreview() else {
            assertionFailure("Could not build preview storage")
            return
        }
        let analysis = sampleAnalysis()
        do {
            _ = try await storage.save(analysis)
            let recent = try await storage.fetchRecent(limit: 10)
            assert(recent.count == 1, "Expected one row after save")
            assert(recent.first?.analysisID == analysis.id, "Saved analysisID mismatch")
            assert(recent.first?.summaryMarkdown == "Hello", "Saved summary mismatch")
            assert(recent.first?.encounterCount == 3, "Saved encounterCount mismatch")
        } catch {
            assertionFailure("Save/fetch threw: \(error)")
        }
    }

    private static func verifyClearAllEmptiesTable() async {
        guard let storage = try? makePreview() else {
            assertionFailure("Could not build preview storage")
            return
        }
        do {
            _ = try await storage.save(sampleAnalysis())
            try await storage.clearAll()
            let recent = try await storage.fetchRecent()
            assert(recent.isEmpty, "clearAll did not empty the table")
        } catch {
            assertionFailure("clearAll threw: \(error)")
        }
    }
}
#endif
```

- [ ] **Step 6: Wire smoke check into the pipeline DEBUG block**

Modify `falsoai-lens/Pipelines/Vision/Services/RealtimeScreenTextPipeline.swift` DEBUG block:

```swift
#if DEBUG
Task {
    await ScreenTextEncounterMemory.runSmokeChecks()
    ScreenTextWindowTracker.runSmokeChecks()
    ScreenTextLLMPreparationService.runSmokeChecks()
    await StubScreenTextWindowAnalyzer.runSmokeChecks()
    await ScreenTextWindowAnalysisStorage.runSmokeChecks()
}
#endif
```

- [ ] **Step 7: Build**

```bash
xcodebuild -project falsoai-lens.xcodeproj -scheme falsoai-lens -configuration Debug build 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 8: Commit**

```bash
git add falsoai-lens/Data/ScreenTextWindowAnalyses falsoai-lens/Pipelines/Vision/Services/RealtimeScreenTextPipeline.swift
git commit -m "$(cat <<'EOF'
feat(vision): persist screen text window analyses in dedicated GRDB store

Add ScreenTextWindowAnalysisStorage (actor) backed by a separate SQLite
file under Application Support/FalsoaiLens/ScreenTextWindowAnalyses.sqlite
with one table indexed by generatedAt and (sessionID, sequenceNumber).
The analyses store is intentionally separate from the per-tick snapshot
cache so durable LLM output and ephemeral OCR samples have independent
lifecycles. DEBUG smoke checks cover the save/fetch round trip and
clearAll.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 7: Persist analyses from the pipeline + expose `recentAnalyses`

The pipeline already produces `ScreenTextWindowAnalysis` values (Task 5). Now route them to disk and surface a `@Published` recent list for the UI.

**Files:**
- Modify: `falsoai-lens/Pipelines/Vision/Services/RealtimeScreenTextPipeline.swift`

- [ ] **Step 1: Add the storage stored property and init parameter**

In `RealtimeScreenTextPipeline.swift`, add after `private let cache: RealtimeScreenTextCache?`:

```swift
private let analysisStorage: ScreenTextWindowAnalysisStorage?
```

Update the published block — add after `lastAnalysisError`:

```swift
@Published private(set) var recentAnalyses: [ScreenTextWindowAnalysisRecord] = []
```

Update the `init` signature to take the storage:

```swift
init(
    sampler: RealtimeScreenTextSampler? = nil,
    cache: RealtimeScreenTextCache? = try? RealtimeScreenTextCache.makeDefault(),
    encounterMemory: ScreenTextEncounterMemory = ScreenTextEncounterMemory(),
    sampleIntervalSeconds: TimeInterval = 1,
    windowAnalyzer: any ScreenTextWindowAnalyzing = StubScreenTextWindowAnalyzer(),
    windowSeconds: TimeInterval = 5 * 60,
    analysisStorage: ScreenTextWindowAnalysisStorage? = try? ScreenTextWindowAnalysisStorage.makeDefault()
) {
    self.sampler = sampler ?? RealtimeScreenTextSampler()
    self.cache = cache
    self.encounterMemory = encounterMemory
    self.sampleIntervalSeconds = max(1, sampleIntervalSeconds)
    self.windowAnalyzer = windowAnalyzer
    self.windowTracker = ScreenTextWindowTracker(windowSeconds: windowSeconds)
    self.analysisStorage = analysisStorage
    refreshRecentSnapshots()
    refreshRecentAnalyses()

    #if DEBUG
    Task {
        await ScreenTextEncounterMemory.runSmokeChecks()
        ScreenTextWindowTracker.runSmokeChecks()
        ScreenTextLLMPreparationService.runSmokeChecks()
        await StubScreenTextWindowAnalyzer.runSmokeChecks()
        await ScreenTextWindowAnalysisStorage.runSmokeChecks()
    }
    #endif
}
```

- [ ] **Step 2: Add `refreshRecentAnalyses()` helper**

Place this near `refreshRecentSnapshots()`:

```swift
func refreshRecentAnalyses() {
    guard let analysisStorage else {
        recentAnalyses = []
        return
    }

    Task {
        do {
            recentAnalyses = try await analysisStorage.fetchRecent(limit: 20)
        } catch {
            logger.error("Refreshing recent analyses failed: \(String(describing: error), privacy: .public)")
        }
    }
}
```

- [ ] **Step 3: Persist on completion in `handleAnalysisCompleted`**

Replace the existing `handleAnalysisCompleted` (added in Task 5) with the version below. The pattern mirrors `clearCache()` in the same file: capture `storage` outside the `Task` so the inner block stays on the inherited `MainActor` isolation without an extra hop.

```swift
private func handleAnalysisCompleted(_ analysis: ScreenTextWindowAnalysis) {
    lastAnalysis = analysis
    lastAnalysisError = nil
    windowsCompleted += 1
    statusText = "Window \(analysis.sequenceNumber) analyzed (\(analysis.encounterCount) lines, \(String(format: "%.2f", analysis.latencySeconds)) s)."
    logger.info("Window analysis completed sequence=\(analysis.sequenceNumber, privacy: .public), encounters=\(analysis.encounterCount, privacy: .public), latencySeconds=\(analysis.latencySeconds, privacy: .public)")

    guard let storage = analysisStorage else { return }
    Task {
        do {
            _ = try await storage.save(analysis)
            self.refreshRecentAnalyses()
        } catch {
            self.recordAnalysisStorageError(error)
        }
    }
}

private func recordAnalysisStorageError(_ error: Error) {
    lastAnalysisError = Self.userFacingMessage(for: error)
    logger.error("Persisting analysis failed: \(String(describing: error), privacy: .public)")
}
```

- [ ] **Step 4: Add `clearAnalyses()` method**

Place after `clearCache()`:

```swift
func clearAnalyses() {
    guard let analysisStorage else { return }

    Task {
        do {
            try await analysisStorage.clearAll()
            recentAnalyses = []
            lastAnalysis = nil
            statusText = "Window analyses cleared."
        } catch {
            errorMessage = Self.userFacingMessage(for: error)
            logger.error("Clearing analyses failed: \(String(describing: error), privacy: .public)")
        }
    }
}
```

- [ ] **Step 5: Build**

```bash
xcodebuild -project falsoai-lens.xcodeproj -scheme falsoai-lens -configuration Debug build 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 6: Commit**

```bash
git add falsoai-lens/Pipelines/Vision/Services/RealtimeScreenTextPipeline.swift
git commit -m "$(cat <<'EOF'
feat(vision): persist completed window analyses and expose recent list

Wire ScreenTextWindowAnalysisStorage into RealtimeScreenTextPipeline so
every successful analyzer run is saved to disk and recentAnalyses is
republished. Add clearAnalyses() for an explicit UI reset that does not
touch the snapshot cache. Storage failures surface via lastAnalysisError
without aborting the recording session.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 8: Surface recent analyses in `ContentView`

Add a panel between the existing realtime sections that shows the latest analysis prominently and lists prior windows.

**Files:**
- Modify: `falsoai-lens/ContentView.swift`

- [ ] **Step 1: Add the panel view builder**

In `ContentView.swift`, find the existing `realtimeClassifierOutputSection` private property and insert this new property immediately below it:

```swift
private var windowAnalysisSection: some View {
    VStack(alignment: .leading, spacing: 10) {
        HStack {
            Text("5-Minute Window Analyses")
                .font(.headline)
            Spacer()
            Text("\(realtimeScreenText.recentAnalyses.count) saved")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button {
                realtimeScreenText.clearAnalyses()
            } label: {
                Label("Clear", systemImage: "trash")
            }
            .disabled(realtimeScreenText.recentAnalyses.isEmpty)
        }

        if let started = realtimeScreenText.currentWindowStartedAt {
            Text("Current window started \(started.formatted(date: .omitted, time: .standard)) — windows completed: \(realtimeScreenText.windowsCompleted)")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else if realtimeScreenText.windowsCompleted > 0 {
            Text("Recording stopped — \(realtimeScreenText.windowsCompleted) window\(realtimeScreenText.windowsCompleted == 1 ? "" : "s") completed this session")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            Text("Start a recording session; the first analysis appears after five minutes of captured text.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        if let lastError = realtimeScreenText.lastAnalysisError {
            Text(lastError)
                .font(.caption)
                .foregroundStyle(.red)
        }

        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                if realtimeScreenText.recentAnalyses.isEmpty {
                    Text("No window analyses yet.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    ForEach(realtimeScreenText.recentAnalyses) { record in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text("Window \(record.sequenceNumber) — \(record.analyzerID)")
                                    .font(.subheadline.weight(.semibold))
                                Spacer()
                                Text(record.generatedAt.formatted(date: .abbreviated, time: .standard))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Text("\(record.encounterCount) lines · \(String(format: "%.2f", record.latencySeconds)) s analyzer")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(record.summaryMarkdown)
                                .font(.system(.body, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(10)
                        .background(Color(nsColor: .textBackgroundColor).opacity(0.6))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                }
            }
            .padding(8)
        }
        .frame(minHeight: 220, maxHeight: 480)
        .background(Color(nsColor: .textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
    .frame(maxWidth: .infinity, alignment: .topLeading)
    .padding()
    .background(.thinMaterial)
    .clipShape(RoundedRectangle(cornerRadius: 8))
}
```

- [ ] **Step 2: Insert the panel into the body**

Find the existing block in the detail view:

```swift
realtimeScreenTextPanel
realtimeEncounteredTextSection
realtimeClassifierOutputSection
realtimeCachedTextSection
```

Replace with:

```swift
realtimeScreenTextPanel
realtimeEncounteredTextSection
windowAnalysisSection
realtimeClassifierOutputSection
realtimeCachedTextSection
```

- [ ] **Step 3: Build**

```bash
xcodebuild -project falsoai-lens.xcodeproj -scheme falsoai-lens -configuration Debug build 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Commit**

```bash
git add falsoai-lens/ContentView.swift
git commit -m "$(cat <<'EOF'
feat(vision): show 5-minute window analyses in ContentView

Add a panel between the encountered-text and classifier sections that
surfaces the latest stub LLM summary, lists prior analyses with
metadata, and exposes a Clear button. Header line tracks current window
start time and number of windows completed in the session so users can
see the flush schedule advance.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 9: End-to-end manual verification with a short window

The default `windowSeconds` is 5 min, which is impractical to verify interactively. Temporarily override it to 30 s, exercise the flow, then revert.

**Files:**
- Modify (temporarily): `falsoai-lens/ContentView.swift`

- [ ] **Step 1: Temporarily override `windowSeconds`**

In `ContentView.swift`, change:

```swift
@StateObject private var realtimeScreenText = RealtimeScreenTextPipeline()
```

to:

```swift
@StateObject private var realtimeScreenText = RealtimeScreenTextPipeline(windowSeconds: 30)
```

- [ ] **Step 2: Build, launch, and exercise**

```bash
xcodebuild -project falsoai-lens.xcodeproj -scheme falsoai-lens -configuration Debug build 2>&1 | tail -5
```

Then open the app from Xcode (or `open` the built app) and:

1. Grant Screen Recording permission if not already granted (see CLAUDE.md "macOS Permissions" notes — `tccutil reset ScreenCapture com.falsoai.FalsoaiLens` if stale).
2. Start the realtime recording.
3. Watch any text-bearing window for ~35 s.

**Expected within ~30 s of starting:**
- Status text in the realtime panel transitions to `Window 1 sealed (... lines); analyzing...` then `Window 1 analyzed (...)`.
- The new `5-Minute Window Analyses` panel populates with a "Window 1" entry whose body starts with `## Stub Window Summary`.
- The encountered-text panel resets (rolling memory was cleared on seal).
- Letting it run another ~30 s produces "Window 2".

**Expected on stop:**
- Status text transitions to "Realtime screen text stopped after caching N changed snapshots."
- `currentWindowStartedAt` indicator clears.
- `recentAnalyses` keeps showing the windows from the just-ended session.

**Expected on Clear (analyses panel):**
- The list empties; `lastAnalysis` clears; status text says "Window analyses cleared."

- [ ] **Step 3: Revert the override**

Change back:

```swift
@StateObject private var realtimeScreenText = RealtimeScreenTextPipeline()
```

- [ ] **Step 4: Build to confirm reverted state still compiles**

```bash
xcodebuild -project falsoai-lens.xcodeproj -scheme falsoai-lens -configuration Debug build 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 5: Commit**

The revert is a no-op compared to Task 8's commit if step 1's edit was never committed — so there should be nothing to commit. Confirm:

```bash
git status
```

If the working tree is dirty (e.g. you committed the override by mistake), revert that file and restate the original. Otherwise this task ends without a commit.

---

## Followups (separate plans)

These came up in the analysis but are intentionally out of scope:

1. **Replace `StubScreenTextWindowAnalyzer` with a real provider** — design considerations: API key handling (Keychain), opt-in privacy gate (CLAUDE.md privacy section), retry/timeout policy, prompt size cap. Plan should also decide whether the `analyzerID` becomes `claude-opus-4-7@2026-05-12` or a stable string.
2. **Strip per-tick LLM exports from `RealtimeScreenTextSnapshot`/cache** — drop `markdownExport`, `compactJSONExport`, `chunkCount` from the model and the cache schema (with a migration). The flush path now produces those on demand from windows.
3. **Demote or delete `RealtimeScreenTextCache`** — its retention semantics (forever, per-tick) no longer match the new "windowed-and-analyzed" model. Either wire `pruneOlderThan` to a periodic task, or delete the cache entirely once the window flow is the source of truth.
4. **Wall-clock window option** — if users want windows that survive `stop()`/`start()` toggling, add a persistent `windowStartedAt` (e.g. `UserDefaults`) and a small recovery path on init.

---

## Self-Review Notes

- **Spec coverage:** the goal "cache text for 5 minutes, then an LLM analyzes the text" is fully covered: the encounter memory is the 5-min cache (existing); the tracker plus pipeline-side seal is the trigger (Tasks 1, 5); the analyzer protocol + stub is the LLM hand-off (Tasks 2, 3, 4); persistence + UI close the loop (Tasks 6, 7, 8); manual verification is structured (Task 9).
- **Type consistency:** `windowSeconds`, `windowID`, `sessionID`, `sequenceNumber`, `analyzerID`, `encounterCount`, `latencySeconds`, `summaryMarkdown`, `errorMessage` are spelled the same across `ScreenTextWindow`, `ScreenTextWindowAnalysis`, `ScreenTextWindowAnalysisRecord`, the analyzer protocol, the storage actor, and the UI panel.
- **No placeholders:** every step has either complete code or a complete command + expected output.
- **TDD adaptation:** the project has no test target, so steps that would be "write the failing test" become "write the failing assertion in `runSmokeChecks` first, then implement". This is faithful to the codebase convention while still putting the assertion before the implementation in time.
