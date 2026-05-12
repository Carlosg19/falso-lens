# Realtime Screen Text Cache Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a realtime screen-text recorder that samples the visible displays on an interval, reuses cached OCR when frames are unchanged, and persists changed text snapshots locally for later retrieval.

**Architecture:** Keep the current one-shot `ScreenTextPipeline` intact and add a separate realtime pipeline. The realtime path should reuse `ScreenCaptureService`, `OCRService`, `ScreenTextDocumentBuilder`, `ScreenTextMemory`, `ScreenTextHasher`, and `ScreenTextLLMExporter`, then write text-only snapshots to a dedicated GRDB cache database. No screenshots or raw pixels are persisted.

**Tech Stack:** Swift, SwiftUI, ScreenCaptureKit screenshot capture, Vision OCR, GRDB, Swift actors, Foundation timers/tasks, existing screen-text models and LLM exporter.

---

## Meta-Analysis

The user wants screen text to be recorded continuously enough to support live context, while caching the text so repeated screen states do not trigger duplicate OCR or duplicate persistence.

The likely root cause is architectural: the app currently has a manual `captureScreenText()` action that performs a one-shot capture, OCR, memory reuse, and optional persistence. That pipeline is valuable, but a realtime recorder needs session lifecycle, cadence, dedupe, persistent snapshot cache, and UI controls that clearly show recording state.

Affected areas:

- `ScreenCaptureService`: reused as the display image source.
- `OCRService`: reused for text extraction; realtime sampling should call it only when a display frame hash misses memory.
- `ScreenTextMemory`: reused per display for in-memory frame/document reuse.
- `ScreenTextHasher`: extended with aggregate hashes for realtime dedupe.
- `ScreenTextLLMExporter`: reused to cache LLM-friendly exports alongside raw recognized text.
- GRDB cache files: new dedicated realtime screen-text cache, modeled after audio transcript cache.
- `ContentView`: adds start/stop controls and a compact recent realtime cache view.

What could break:

- UI responsiveness if OCR runs too frequently.
- Screen Recording permission UX if realtime start repeatedly prompts or fails noisily.
- Storage growth if every interval is persisted.
- Duplicate records if frame hashes differ but normalized text is unchanged.
- MainActor pressure because the project defaults to `MainActor` isolation.

Verification:

- Compile small smoke harnesses for cache record round-trips and dedupe logic.
- Run the full Debug build with `xcodebuild -project falsoai-lens.xcodeproj -scheme falsoai-lens -configuration Debug build`.
- Manual run: start realtime screen text, leave a static screen for at least three intervals, confirm only the first changed snapshot is cached; change visible text, confirm a new snapshot appears; stop recording and confirm status becomes idle.

## Scope

This plan implements sampled realtime capture. It does not implement raw `SCStream` video-frame OCR. Sampling every two seconds is deliberate: OCR is CPU-heavy and the app should avoid turning screen reading into a continuous UI-blocking workload.

The realtime recorder will:

- Start and stop from the UI.
- Capture all displays at a configurable interval.
- Use per-display frame hashes to skip OCR for unchanged displays.
- Build a `MultiDisplayScreenTextDocument` for each sample.
- Persist only changed aggregate text/layout snapshots.
- Cache recognized text, markdown export, compact JSON export, chunk count, display count, hashes, and timing metadata.
- Avoid saving screenshots, raw images, or pixel buffers.

The realtime recorder will not:

- Upload text or screenshots.
- Persist raw images.
- Replace the existing one-shot capture button.
- Run manipulation heuristics or LLM calls.
- Attempt sub-second OCR.

## File Structure

Phase 1 creates cache/data contracts:

- Create `falsoai-lens/Pipelines/Vision/Models/RealtimeScreenTextSnapshot.swift`
  - Value model emitted by realtime sampling.
  - Stores session ID, sequence number, source document, hashes, export strings, and timing metadata.

- Create `falsoai-lens/Data/ScreenTextCache/Records/RealtimeScreenTextSnapshotRecord.swift`
  - GRDB row model for text-only cached snapshots.

- Create `falsoai-lens/Data/ScreenTextCache/RealtimeScreenTextCacheDatabase.swift`
  - Owns the GRDB `DatabaseQueue` and default cache path.

- Create `falsoai-lens/Data/ScreenTextCache/RealtimeScreenTextCacheMigrations.swift`
  - Owns cache table creation and indexes.

- Create `falsoai-lens/Data/ScreenTextCache/RealtimeScreenTextCache.swift`
  - Actor API for saving, fetching, clearing, and pruning realtime text snapshots.

Phase 2 creates realtime capture orchestration:

- Modify `falsoai-lens/Pipelines/Vision/Services/ScreenTextHasher.swift`
  - Add aggregate realtime hash helpers.

- Create `falsoai-lens/Pipelines/Vision/Services/RealtimeScreenTextSampler.swift`
  - Performs one realtime sample using existing capture/OCR/builder/exporter services.

- Create `falsoai-lens/Pipelines/Vision/Services/RealtimeScreenTextPipeline.swift`
  - `@MainActor ObservableObject` that manages start/stop lifecycle and publishes status.

Phase 3 exposes the feature:

- Modify `falsoai-lens/ContentView.swift`
  - Adds live screen text controls and recent cached snapshot list.

Phase 4 verifies behavior:

- Create `/private/tmp/falsoai-lens-realtime-screen-text-cache-tests/main.swift`
  - Temporary smoke harness because this Xcode project has no configured test target.

---

### Task 1: Add Realtime Snapshot Model

**Files:**

- Create: `falsoai-lens/Pipelines/Vision/Models/RealtimeScreenTextSnapshot.swift`

- [ ] **Step 1: Create the snapshot model**

Use this exact file content:

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

- [ ] **Step 2: Typecheck the model with existing screen text models**

Run:

```bash
xcrun swiftc \
  falsoai-lens/Pipelines/Vision/Models/ScreenTextDocument.swift \
  falsoai-lens/Pipelines/Vision/Models/ScreenTextLLMDocument.swift \
  falsoai-lens/Pipelines/Vision/Models/RealtimeScreenTextSnapshot.swift \
  -typecheck
```

Expected:

```text
No output and exit code 0.
```

- [ ] **Step 3: Commit**

```bash
git add falsoai-lens/Pipelines/Vision/Models/RealtimeScreenTextSnapshot.swift
git commit -m "feat: add realtime screen text snapshot model"
```

---

### Task 2: Add Persistent Realtime Screen Text Cache

**Files:**

- Create: `falsoai-lens/Data/ScreenTextCache/Records/RealtimeScreenTextSnapshotRecord.swift`
- Create: `falsoai-lens/Data/ScreenTextCache/RealtimeScreenTextCacheDatabase.swift`
- Create: `falsoai-lens/Data/ScreenTextCache/RealtimeScreenTextCacheMigrations.swift`
- Create: `falsoai-lens/Data/ScreenTextCache/RealtimeScreenTextCache.swift`

- [ ] **Step 1: Create the GRDB record**

Use this exact file content:

```swift
import Foundation
import GRDB

struct RealtimeScreenTextSnapshotRecord: Codable, FetchableRecord, PersistableRecord, Identifiable, Equatable {
    static let databaseTableName = "realtime_screen_text_snapshots"

    var id: Int64?
    var capturedAt: Date
    var sessionID: UUID
    var sequenceNumber: Int
    var displayCount: Int
    var observationCount: Int
    var lineCount: Int
    var blockCount: Int
    var regionCount: Int
    var recognizedText: String
    var markdownExport: String
    var compactJSONExport: String
    var chunkCount: Int
    var aggregateTextHash: String
    var aggregateLayoutHash: String
    var displayFrameHashesJSON: String
    var reusedDisplayCount: Int
    var ocrDisplayCount: Int
    var elapsedSeconds: Double
}
```

- [ ] **Step 2: Create the cache database wrapper**

Use this exact file content:

```swift
import Foundation
import GRDB

final class RealtimeScreenTextCacheDatabase {
    let dbQueue: DatabaseQueue

    nonisolated init(databaseURL: URL) throws {
        dbQueue = try DatabaseQueue(path: databaseURL.path)
        try RealtimeScreenTextCacheMigrations.migrator.migrate(dbQueue)
    }

    nonisolated static func makeDefault() throws -> RealtimeScreenTextCacheDatabase {
        try RealtimeScreenTextCacheDatabase(databaseURL: defaultDatabaseURL())
    }

    nonisolated static func makePreview() throws -> RealtimeScreenTextCacheDatabase {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("FalsoaiLensRealtimeScreenTextCache-\(UUID().uuidString).sqlite")
        return try RealtimeScreenTextCacheDatabase(databaseURL: url)
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

        return directoryURL.appendingPathComponent("RealtimeScreenTextCache.sqlite")
    }
}
```

- [ ] **Step 3: Create the migrations**

Use this exact file content:

```swift
import GRDB

enum RealtimeScreenTextCacheMigrations {
    nonisolated static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("createRealtimeScreenTextSnapshots") { db in
            try db.create(table: RealtimeScreenTextSnapshotRecord.databaseTableName, ifNotExists: true) { table in
                table.autoIncrementedPrimaryKey("id")
                table.column("capturedAt", .datetime).notNull()
                table.column("sessionID", .text).notNull()
                table.column("sequenceNumber", .integer).notNull()
                table.column("displayCount", .integer).notNull()
                table.column("observationCount", .integer).notNull()
                table.column("lineCount", .integer).notNull()
                table.column("blockCount", .integer).notNull()
                table.column("regionCount", .integer).notNull()
                table.column("recognizedText", .text).notNull()
                table.column("markdownExport", .text).notNull()
                table.column("compactJSONExport", .text).notNull()
                table.column("chunkCount", .integer).notNull()
                table.column("aggregateTextHash", .text).notNull()
                table.column("aggregateLayoutHash", .text).notNull()
                table.column("displayFrameHashesJSON", .text).notNull()
                table.column("reusedDisplayCount", .integer).notNull()
                table.column("ocrDisplayCount", .integer).notNull()
                table.column("elapsedSeconds", .double).notNull()
                table.uniqueKey(["sessionID", "sequenceNumber"])
            }

            try db.create(
                index: "realtime_screen_text_snapshots_capturedAt",
                on: RealtimeScreenTextSnapshotRecord.databaseTableName,
                columns: ["capturedAt"]
            )
            try db.create(
                index: "realtime_screen_text_snapshots_session_sequence",
                on: RealtimeScreenTextSnapshotRecord.databaseTableName,
                columns: ["sessionID", "sequenceNumber"]
            )
            try db.create(
                index: "realtime_screen_text_snapshots_text_layout",
                on: RealtimeScreenTextSnapshotRecord.databaseTableName,
                columns: ["aggregateTextHash", "aggregateLayoutHash"]
            )
        }

        return migrator
    }
}
```

- [ ] **Step 4: Create the cache actor**

Use this exact file content:

```swift
import Foundation
import GRDB

actor RealtimeScreenTextCache {
    private let database: RealtimeScreenTextCacheDatabase

    init(database: RealtimeScreenTextCacheDatabase) {
        self.database = database
    }

    static func makeDefault() throws -> RealtimeScreenTextCache {
        try RealtimeScreenTextCache(database: .makeDefault())
    }

    static func makePreview() throws -> RealtimeScreenTextCache {
        try RealtimeScreenTextCache(database: .makePreview())
    }

    @discardableResult
    func save(_ snapshot: RealtimeScreenTextSnapshot) throws -> RealtimeScreenTextSnapshotRecord {
        let displayFrameHashesJSON = try Self.displayFrameHashesJSON(from: snapshot.displayFrameHashes)
        let record = RealtimeScreenTextSnapshotRecord(
            id: nil,
            capturedAt: snapshot.capturedAt,
            sessionID: snapshot.sessionID,
            sequenceNumber: snapshot.sequenceNumber,
            displayCount: snapshot.displayCount,
            observationCount: snapshot.observationCount,
            lineCount: snapshot.lineCount,
            blockCount: snapshot.blockCount,
            regionCount: snapshot.regionCount,
            recognizedText: snapshot.recognizedText,
            markdownExport: snapshot.markdownExport,
            compactJSONExport: snapshot.compactJSONExport,
            chunkCount: snapshot.chunkCount,
            aggregateTextHash: snapshot.aggregateTextHash,
            aggregateLayoutHash: snapshot.aggregateLayoutHash,
            displayFrameHashesJSON: displayFrameHashesJSON,
            reusedDisplayCount: snapshot.reusedDisplayCount,
            ocrDisplayCount: snapshot.ocrDisplayCount,
            elapsedSeconds: snapshot.elapsedSeconds
        )

        return try database.dbQueue.write { db in
            var mutableRecord = record
            try mutableRecord.insert(db)
            mutableRecord.id = db.lastInsertedRowID
            return mutableRecord
        }
    }

    func fetchRecent(limit: Int = 100) throws -> [RealtimeScreenTextSnapshotRecord] {
        try database.dbQueue.read { db in
            try RealtimeScreenTextSnapshotRecord.fetchAll(
                db,
                sql: """
                    SELECT *
                    FROM realtime_screen_text_snapshots
                    ORDER BY capturedAt DESC, id DESC
                    LIMIT ?
                    """,
                arguments: [limit]
            )
        }
    }

    func clearAll() throws {
        try database.dbQueue.write { db in
            try db.execute(sql: "DELETE FROM realtime_screen_text_snapshots")
        }
    }

    func pruneOlderThan(_ cutoff: Date) throws {
        try database.dbQueue.write { db in
            try db.execute(
                sql: "DELETE FROM realtime_screen_text_snapshots WHERE capturedAt < ?",
                arguments: [cutoff]
            )
        }
    }

    private static func displayFrameHashesJSON(from hashes: [String]) throws -> String {
        let data = try JSONEncoder().encode(hashes)
        return String(decoding: data, as: UTF8.self)
    }
}
```

- [ ] **Step 5: Typecheck the cache files**

Run:

```bash
xcrun swiftc \
  falsoai-lens/Pipelines/Vision/Models/ScreenTextDocument.swift \
  falsoai-lens/Pipelines/Vision/Models/ScreenTextLLMDocument.swift \
  falsoai-lens/Pipelines/Vision/Models/RealtimeScreenTextSnapshot.swift \
  falsoai-lens/Data/ScreenTextCache/Records/RealtimeScreenTextSnapshotRecord.swift \
  falsoai-lens/Data/ScreenTextCache/RealtimeScreenTextCacheDatabase.swift \
  falsoai-lens/Data/ScreenTextCache/RealtimeScreenTextCacheMigrations.swift \
  falsoai-lens/Data/ScreenTextCache/RealtimeScreenTextCache.swift \
  -typecheck
```

Expected:

```text
No output and exit code 0.
```

- [ ] **Step 6: Commit**

```bash
git add \
  falsoai-lens/Pipelines/Vision/Models/RealtimeScreenTextSnapshot.swift \
  falsoai-lens/Data/ScreenTextCache/Records/RealtimeScreenTextSnapshotRecord.swift \
  falsoai-lens/Data/ScreenTextCache/RealtimeScreenTextCacheDatabase.swift \
  falsoai-lens/Data/ScreenTextCache/RealtimeScreenTextCacheMigrations.swift \
  falsoai-lens/Data/ScreenTextCache/RealtimeScreenTextCache.swift
git commit -m "feat: add realtime screen text cache"
```

---

### Task 3: Add Aggregate Hash Helpers

**Files:**

- Modify: `falsoai-lens/Pipelines/Vision/Services/ScreenTextHasher.swift`

- [ ] **Step 1: Add aggregate hash methods**

Inside `ScreenTextHasher`, below `hashLayout(observations:)`, add:

```swift
    static func hashAggregateText(_ document: MultiDisplayScreenTextDocument) -> String {
        let canonicalText = document.displays
            .sorted { $0.index < $1.index }
            .map { display in
                [
                    "display:\(display.displayID)",
                    normalizeText(display.document.recognizedText)
                ].joined(separator: "|")
            }
            .joined(separator: "\n")

        return hashString(canonicalText)
    }

    static func hashAggregateLayout(_ document: MultiDisplayScreenTextDocument) -> String {
        let canonicalLayout = document.displays
            .sorted { $0.index < $1.index }
            .map { display in
                [
                    "display:\(display.displayID)",
                    display.document.layoutHash
                ].joined(separator: "|")
            }
            .joined(separator: "\n")

        return hashString(canonicalLayout)
    }
```

- [ ] **Step 2: Typecheck hasher with models**

Run:

```bash
xcrun swiftc \
  falsoai-lens/Pipelines/Vision/Models/ScreenTextDocument.swift \
  falsoai-lens/Pipelines/Vision/Services/ScreenTextHasher.swift \
  -typecheck
```

Expected:

```text
No output and exit code 0.
```

- [ ] **Step 3: Commit**

```bash
git add falsoai-lens/Pipelines/Vision/Services/ScreenTextHasher.swift
git commit -m "feat: add aggregate screen text hashes"
```

---

### Task 4: Add Realtime Sampler

**Files:**

- Create: `falsoai-lens/Pipelines/Vision/Services/RealtimeScreenTextSampler.swift`

- [ ] **Step 1: Create the sampler service**

Use this exact file content:

```swift
import CoreGraphics
import Foundation
import OSLog

@MainActor
final class RealtimeScreenTextSampler {
    private let screenCaptureService: ScreenCaptureService
    private let ocrService: OCRService
    private let documentBuilder: ScreenTextDocumentBuilder
    private let exporter: ScreenTextLLMExporter
    private var displayMemories: [UInt32: ScreenTextMemory] = [:]
    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.falsoai.FalsoaiLens",
        category: "RealtimeScreenTextSampler"
    )

    init(
        screenCaptureService: ScreenCaptureService = ScreenCaptureService(),
        ocrService: OCRService = OCRService(),
        documentBuilder: ScreenTextDocumentBuilder = ScreenTextDocumentBuilder(),
        exporter: ScreenTextLLMExporter = ScreenTextLLMExporter()
    ) {
        self.screenCaptureService = screenCaptureService
        self.ocrService = ocrService
        self.documentBuilder = documentBuilder
        self.exporter = exporter
    }

    func sample(sessionID: UUID, sequenceNumber: Int) async throws -> RealtimeScreenTextSnapshot {
        let started = Date()
        let frames = try await screenCaptureService.captureAllDisplayImages()
        let capturedAt = Date()

        var displayDocuments: [DisplayScreenTextDocument] = []
        var displayFrameHashes: [String] = []
        var reusedDisplayCount = 0
        var ocrDisplayCount = 0

        for frame in frames {
            let frameHash = ScreenTextHasher.displayFrameHash(
                displayID: frame.displayID,
                image: frame.image
            )
            displayFrameHashes.append(frameHash)

            let memory = memory(forDisplayID: frame.displayID)
            if let cachedDocument = await memory.cachedDocument(forFrameHash: frameHash) {
                reusedDisplayCount += 1
                displayDocuments.append(
                    DisplayScreenTextDocument(
                        displayID: frame.displayID,
                        index: frame.index,
                        document: cachedDocument
                    )
                )
                continue
            }

            ocrDisplayCount += 1
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

        let document = MultiDisplayScreenTextDocument(
            capturedAt: capturedAt,
            displays: displayDocuments.sorted { $0.index < $1.index }
        )
        let exportedDocument = exporter.export(document)
        let markdown = exporter.anchoredMarkdown(from: exportedDocument)
        let compactJSON = try exporter.compactJSON(from: exportedDocument)
        let chunks = exporter.chunks(from: exportedDocument)
        let recognizedText = document.recognizedText.trimmingCharacters(in: .whitespacesAndNewlines)

        logger.info(
            "Realtime screen text sample sequence=\(sequenceNumber, privacy: .public), displays=\(document.displays.count, privacy: .public), characters=\(recognizedText.count, privacy: .public), reusedDisplays=\(reusedDisplayCount, privacy: .public), ocrDisplays=\(ocrDisplayCount, privacy: .public)"
        )

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
            elapsedSeconds: Date().timeIntervalSince(started)
        )
    }

    private func memory(forDisplayID displayID: UInt32) -> ScreenTextMemory {
        if let memory = displayMemories[displayID] {
            return memory
        }

        let memory = ScreenTextMemory()
        displayMemories[displayID] = memory
        return memory
    }
}
```

- [ ] **Step 2: Verify sampler typechecking**

Run:

```bash
xcrun swiftc \
  falsoai-lens/Pipelines/Vision/Models/ScreenTextDocument.swift \
  falsoai-lens/Pipelines/Vision/Models/ScreenTextLLMDocument.swift \
  falsoai-lens/Pipelines/Vision/Models/RealtimeScreenTextSnapshot.swift \
  falsoai-lens/Pipelines/Vision/Services/ScreenTextHasher.swift \
  falsoai-lens/Pipelines/Vision/Services/ScreenTextMemory.swift \
  falsoai-lens/Pipelines/Vision/Services/ScreenTextDocumentBuilder.swift \
  falsoai-lens/Pipelines/Vision/Services/ScreenTextLLMExporter.swift \
  falsoai-lens/Pipelines/Vision/Services/OCRService.swift \
  falsoai-lens/Pipelines/Vision/Services/ScreenCaptureService.swift \
  falsoai-lens/Pipelines/Vision/Services/RealtimeScreenTextSampler.swift \
  -typecheck
```

Expected:

```text
No output and exit code 0.
```

- [ ] **Step 3: Commit**

```bash
git add falsoai-lens/Pipelines/Vision/Services/RealtimeScreenTextSampler.swift
git commit -m "feat: add realtime screen text sampler"
```

---

### Task 5: Add Realtime Pipeline Controller

**Files:**

- Create: `falsoai-lens/Pipelines/Vision/Services/RealtimeScreenTextPipeline.swift`

- [ ] **Step 1: Create the pipeline controller**

Use this exact file content:

```swift
import Combine
import Foundation
import OSLog

@MainActor
final class RealtimeScreenTextPipeline: ObservableObject {
    @Published private(set) var isRunning = false
    @Published private(set) var isSampling = false
    @Published private(set) var statusText = "Realtime screen text is stopped."
    @Published private(set) var errorMessage: String?
    @Published private(set) var latestSnapshot: RealtimeScreenTextSnapshot?
    @Published private(set) var recentSnapshots: [RealtimeScreenTextSnapshotRecord] = []
    @Published private(set) var samplesCaptured = 0
    @Published private(set) var snapshotsCached = 0
    @Published private(set) var duplicateSamplesSkipped = 0

    private let sampler: RealtimeScreenTextSampler
    private let cache: RealtimeScreenTextCache?
    private let sampleIntervalSeconds: TimeInterval
    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.falsoai.FalsoaiLens",
        category: "RealtimeScreenTextPipeline"
    )
    private var captureTask: Task<Void, Never>?
    private var sessionID = UUID()
    private var sequenceNumber = 0
    private var lastCachedTextHash: String?
    private var lastCachedLayoutHash: String?

    init(
        sampler: RealtimeScreenTextSampler = RealtimeScreenTextSampler(),
        cache: RealtimeScreenTextCache? = try? RealtimeScreenTextCache.makeDefault(),
        sampleIntervalSeconds: TimeInterval = 2
    ) {
        self.sampler = sampler
        self.cache = cache
        self.sampleIntervalSeconds = max(1, sampleIntervalSeconds)
        refreshRecentSnapshots()
    }

    func start() {
        guard !isRunning else { return }

        sessionID = UUID()
        sequenceNumber = 0
        lastCachedTextHash = nil
        lastCachedLayoutHash = nil
        samplesCaptured = 0
        snapshotsCached = 0
        duplicateSamplesSkipped = 0
        errorMessage = nil
        isRunning = true
        statusText = "Realtime screen text is starting..."

        captureTask = Task { [weak self] in
            await self?.runLoop()
        }
    }

    func stop() {
        captureTask?.cancel()
        captureTask = nil
        isRunning = false
        isSampling = false
        statusText = snapshotsCached > 0
            ? "Realtime screen text stopped after caching \(snapshotsCached) changed snapshots."
            : "Realtime screen text is stopped."
        logger.info("Realtime screen text stopped cachedSnapshots=\(self.snapshotsCached, privacy: .public), duplicateSamplesSkipped=\(self.duplicateSamplesSkipped, privacy: .public)")
    }

    func refreshRecentSnapshots() {
        guard let cache else {
            recentSnapshots = []
            return
        }

        Task {
            do {
                recentSnapshots = try await cache.fetchRecent(limit: 20)
            } catch {
                logger.error("Realtime screen text cache refresh failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    func clearCache() {
        guard let cache else { return }

        Task {
            do {
                try await cache.clearAll()
                recentSnapshots = []
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

    private func runLoop() async {
        while !Task.isCancelled {
            await captureOneSample()

            do {
                let nanoseconds = UInt64(sampleIntervalSeconds * 1_000_000_000)
                try await Task.sleep(nanoseconds: nanoseconds)
            } catch {
                break
            }
        }
    }

    private func captureOneSample() async {
        sequenceNumber += 1
        isSampling = true
        statusText = "Reading screen text sample \(sequenceNumber)..."
        defer { isSampling = false }

        do {
            let snapshot = try await sampler.sample(
                sessionID: sessionID,
                sequenceNumber: sequenceNumber
            )
            samplesCaptured += 1
            latestSnapshot = snapshot

            guard snapshot.hasReadableText else {
                statusText = "Screen sample \(sequenceNumber) had no readable text."
                return
            }

            guard shouldCache(snapshot) else {
                duplicateSamplesSkipped += 1
                statusText = "Screen text unchanged; skipped duplicate sample \(sequenceNumber)."
                return
            }

            try await cache?.save(snapshot)
            lastCachedTextHash = snapshot.aggregateTextHash
            lastCachedLayoutHash = snapshot.aggregateLayoutHash
            snapshotsCached += 1
            refreshRecentSnapshots()
            statusText = "Cached screen text sample \(sequenceNumber) with \(snapshot.recognizedText.count) characters."
        } catch {
            errorMessage = Self.userFacingMessage(for: error)
            statusText = "Realtime screen text sample failed."
            logger.error("Realtime screen text sample failed: \(String(describing: error), privacy: .public)")
        }
    }

    private func shouldCache(_ snapshot: RealtimeScreenTextSnapshot) -> Bool {
        snapshot.aggregateTextHash != lastCachedTextHash
            || snapshot.aggregateLayoutHash != lastCachedLayoutHash
    }

    private nonisolated static func userFacingMessage(for error: Error) -> String {
        if let localizedError = error as? LocalizedError {
            let message = localizedError.errorDescription ?? error.localizedDescription
            let suggestion = localizedError.recoverySuggestion ?? ""
            return suggestion.isEmpty ? message : "\(message) \(suggestion)"
        }

        return error.localizedDescription
    }
}
```

- [ ] **Step 2: Typecheck the realtime pipeline**

Run:

```bash
xcrun swiftc \
  falsoai-lens/Pipelines/Vision/Models/ScreenTextDocument.swift \
  falsoai-lens/Pipelines/Vision/Models/ScreenTextLLMDocument.swift \
  falsoai-lens/Pipelines/Vision/Models/RealtimeScreenTextSnapshot.swift \
  falsoai-lens/Data/ScreenTextCache/Records/RealtimeScreenTextSnapshotRecord.swift \
  falsoai-lens/Data/ScreenTextCache/RealtimeScreenTextCacheDatabase.swift \
  falsoai-lens/Data/ScreenTextCache/RealtimeScreenTextCacheMigrations.swift \
  falsoai-lens/Data/ScreenTextCache/RealtimeScreenTextCache.swift \
  falsoai-lens/Pipelines/Vision/Services/ScreenTextHasher.swift \
  falsoai-lens/Pipelines/Vision/Services/ScreenTextMemory.swift \
  falsoai-lens/Pipelines/Vision/Services/ScreenTextDocumentBuilder.swift \
  falsoai-lens/Pipelines/Vision/Services/ScreenTextLLMExporter.swift \
  falsoai-lens/Pipelines/Vision/Services/OCRService.swift \
  falsoai-lens/Pipelines/Vision/Services/ScreenCaptureService.swift \
  falsoai-lens/Pipelines/Vision/Services/RealtimeScreenTextSampler.swift \
  falsoai-lens/Pipelines/Vision/Services/RealtimeScreenTextPipeline.swift \
  -typecheck
```

Expected:

```text
No output and exit code 0.
```

- [ ] **Step 3: Commit**

```bash
git add falsoai-lens/Pipelines/Vision/Services/RealtimeScreenTextPipeline.swift
git commit -m "feat: add realtime screen text pipeline"
```

---

### Task 6: Add Realtime Controls to ContentView

**Files:**

- Modify: `falsoai-lens/ContentView.swift`

- [ ] **Step 1: Add the realtime pipeline state object**

Below:

```swift
    @StateObject private var screenText = ScreenTextPipeline()
```

Add:

```swift
    @StateObject private var realtimeScreenText = RealtimeScreenTextPipeline()
```

- [ ] **Step 2: Refresh realtime snapshots from the toolbar**

Inside the existing toolbar `Button("Refresh")`, below:

```swift
                    screenText.refreshRecentCaptures()
```

Add:

```swift
                    realtimeScreenText.refreshRecentSnapshots()
```

- [ ] **Step 3: Add a recent realtime cache sidebar section**

Below the existing `Section("Recent Screen Text")`, add:

```swift
                Section("Realtime Screen Text Cache") {
                    if realtimeScreenText.recentSnapshots.isEmpty {
                        Text("No realtime snapshots yet")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(realtimeScreenText.recentSnapshots) { snapshot in
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Sample \(snapshot.sequenceNumber)")
                                    .font(.headline)
                                Text(snapshot.recognizedText)
                                    .lineLimit(2)
                                    .foregroundStyle(.secondary)
                                Text("\(snapshot.displayCount) displays | \(snapshot.recognizedText.count) chars | \(snapshot.capturedAt.formatted(date: .omitted, time: .standard))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }
```

- [ ] **Step 4: Add the realtime control panel**

Below the one-shot capture status text:

```swift
                    Text(screenText.captureStatus)
                        .font(.callout)
                        .foregroundStyle(.secondary)
```

Add:

```swift
                    realtimeScreenTextPanel
```

- [ ] **Step 5: Add the realtime panel view**

Below `screenTextExportText(markdown:chunks:)`, add:

```swift
    private var realtimeScreenTextPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Realtime Screen Text")
                    .font(.headline)
                Spacer()
                Text(realtimeScreenText.isRunning ? "Recording" : "Stopped")
                    .font(.caption)
                    .foregroundStyle(realtimeScreenText.isRunning ? .green : .secondary)
            }

            HStack {
                Button {
                    if realtimeScreenText.isRunning {
                        realtimeScreenText.stop()
                    } else {
                        realtimeScreenText.start()
                    }
                } label: {
                    Label(
                        realtimeScreenText.isRunning ? "Stop" : "Start",
                        systemImage: realtimeScreenText.isRunning ? "stop.circle" : "record.circle"
                    )
                }

                Button {
                    realtimeScreenText.clearCache()
                } label: {
                    Label("Clear Cache", systemImage: "trash")
                }
                .disabled(realtimeScreenText.isRunning || realtimeScreenText.recentSnapshots.isEmpty)

                Spacer()

                if realtimeScreenText.isSampling {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            HStack(spacing: 12) {
                Label("\(realtimeScreenText.samplesCaptured) samples", systemImage: "camera.metering.center.weighted")
                Label("\(realtimeScreenText.snapshotsCached) cached", systemImage: "externaldrive")
                Label("\(realtimeScreenText.duplicateSamplesSkipped) duplicates skipped", systemImage: "equal.circle")
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            Text(realtimeScreenText.statusText)
                .font(.callout)
                .foregroundStyle(.secondary)

            if let latestSnapshot = realtimeScreenText.latestSnapshot {
                Text("\(latestSnapshot.displayCount) displays | \(latestSnapshot.observationCount) observations | \(latestSnapshot.ocrDisplayCount) OCR displays | \(latestSnapshot.reusedDisplayCount) cached displays | \(latestSnapshot.elapsedSeconds.formatted(.number.precision(.fractionLength(2))))s")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            if let errorMessage = realtimeScreenText.errorMessage {
                Text(errorMessage)
                    .font(.callout)
                    .foregroundStyle(.red)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .padding()
        .background(.thinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
```

- [ ] **Step 6: Stop realtime capture when the view disappears**

Add this modifier after the existing `.task { ... }` block on `body`:

```swift
        .onDisappear {
            realtimeScreenText.stop()
        }
```

- [ ] **Step 7: Build the app**

Run:

```bash
xcodebuild -project falsoai-lens.xcodeproj -scheme falsoai-lens -configuration Debug build
```

Expected:

```text
** BUILD SUCCEEDED **
```

- [ ] **Step 8: Commit**

```bash
git add falsoai-lens/ContentView.swift
git commit -m "feat: expose realtime screen text cache"
```

---

### Task 7: Add Cache Smoke Check

**Files:**

- Create: `/private/tmp/falsoai-lens-realtime-screen-text-cache-tests/main.swift`

- [ ] **Step 1: Create the smoke harness**

Use this exact file content:

```swift
import CoreGraphics
import Foundation

func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

let capturedAt = Date()
let observation = ScreenTextObservation(
    text: "Realtime cache smoke check",
    boundingBox: CGRect(x: 10, y: 20, width: 300, height: 24),
    confidence: 0.98
)
let document = ScreenTextDocument(
    capturedAt: capturedAt,
    frameSize: CGSize(width: 1440, height: 900),
    frameHash: "display-1-frame-a",
    normalizedTextHash: ScreenTextHasher.hashNormalizedText("Realtime cache smoke check"),
    layoutHash: ScreenTextHasher.hashLayout(observations: [observation]),
    observations: [observation],
    lines: [
        ScreenTextLine(
            text: "Realtime cache smoke check",
            boundingBox: observation.boundingBox,
            observationIDs: [observation.id]
        )
    ],
    blocks: [
        ScreenTextBlock(
            text: "Realtime cache smoke check",
            boundingBox: observation.boundingBox,
            lineIDs: []
        )
    ],
    regions: []
)
let aggregate = MultiDisplayScreenTextDocument(
    capturedAt: capturedAt,
    displays: [
        DisplayScreenTextDocument(displayID: 1, index: 0, document: document)
    ]
)
let exporter = ScreenTextLLMExporter()
let exported = exporter.export(aggregate)
let snapshot = RealtimeScreenTextSnapshot(
    sessionID: UUID(),
    sequenceNumber: 1,
    capturedAt: capturedAt,
    document: aggregate,
    recognizedText: aggregate.recognizedText,
    markdownExport: exporter.anchoredMarkdown(from: exported),
    compactJSONExport: try exporter.compactJSON(from: exported),
    chunkCount: exporter.chunks(from: exported).count,
    displayCount: aggregate.displays.count,
    observationCount: aggregate.observationCount,
    lineCount: aggregate.lineCount,
    blockCount: aggregate.blockCount,
    regionCount: aggregate.regionCount,
    aggregateTextHash: ScreenTextHasher.hashAggregateText(aggregate),
    aggregateLayoutHash: ScreenTextHasher.hashAggregateLayout(aggregate),
    displayFrameHashes: ["display-1-frame-a"],
    reusedDisplayCount: 0,
    ocrDisplayCount: 1,
    elapsedSeconds: 0.12
)

let cache = try RealtimeScreenTextCache.makePreview()
let saved = try await cache.save(snapshot)
expect(saved.id != nil, "saved record should have an id")
expect(saved.sequenceNumber == 1, "sequence number should round-trip")
expect(saved.recognizedText.contains("Realtime cache smoke check"), "recognized text should round-trip")

let recent = try await cache.fetchRecent(limit: 10)
expect(recent.count == 1, "cache should contain one record")
expect(recent[0].aggregateTextHash == snapshot.aggregateTextHash, "aggregate text hash should round-trip")
expect(recent[0].aggregateLayoutHash == snapshot.aggregateLayoutHash, "aggregate layout hash should round-trip")

try await cache.clearAll()
let cleared = try await cache.fetchRecent(limit: 10)
expect(cleared.isEmpty, "cache should clear all records")

print("Realtime screen text cache smoke check passed")
```

- [ ] **Step 2: Compile and run the smoke harness**

Run:

```bash
xcrun swiftc \
  falsoai-lens/Pipelines/Vision/Models/ScreenTextDocument.swift \
  falsoai-lens/Pipelines/Vision/Models/ScreenTextLLMDocument.swift \
  falsoai-lens/Pipelines/Vision/Models/RealtimeScreenTextSnapshot.swift \
  falsoai-lens/Pipelines/Vision/Services/ScreenTextHasher.swift \
  falsoai-lens/Pipelines/Vision/Services/ScreenTextLLMExporter.swift \
  falsoai-lens/Data/ScreenTextCache/Records/RealtimeScreenTextSnapshotRecord.swift \
  falsoai-lens/Data/ScreenTextCache/RealtimeScreenTextCacheDatabase.swift \
  falsoai-lens/Data/ScreenTextCache/RealtimeScreenTextCacheMigrations.swift \
  falsoai-lens/Data/ScreenTextCache/RealtimeScreenTextCache.swift \
  /private/tmp/falsoai-lens-realtime-screen-text-cache-tests/main.swift \
  -o /private/tmp/falsoai-lens-realtime-screen-text-cache-tests/check \
  && /private/tmp/falsoai-lens-realtime-screen-text-cache-tests/check
```

Expected:

```text
Realtime screen text cache smoke check passed
```

- [ ] **Step 3: Run the full build**

Run:

```bash
xcodebuild -project falsoai-lens.xcodeproj -scheme falsoai-lens -configuration Debug build
```

Expected:

```text
** BUILD SUCCEEDED **
```

- [ ] **Step 4: Commit**

```bash
git add \
  falsoai-lens/Pipelines/Vision/Models/RealtimeScreenTextSnapshot.swift \
  falsoai-lens/Data/ScreenTextCache/Records/RealtimeScreenTextSnapshotRecord.swift \
  falsoai-lens/Data/ScreenTextCache/RealtimeScreenTextCacheDatabase.swift \
  falsoai-lens/Data/ScreenTextCache/RealtimeScreenTextCacheMigrations.swift \
  falsoai-lens/Data/ScreenTextCache/RealtimeScreenTextCache.swift \
  falsoai-lens/Pipelines/Vision/Services/ScreenTextHasher.swift \
  falsoai-lens/Pipelines/Vision/Services/RealtimeScreenTextSampler.swift \
  falsoai-lens/Pipelines/Vision/Services/RealtimeScreenTextPipeline.swift \
  falsoai-lens/ContentView.swift
git commit -m "test: verify realtime screen text cache"
```

---

## Manual Verification

- [ ] Launch the app from Xcode.
- [ ] Confirm Screen Recording permission is authorized in the permissions list.
- [ ] Click `Start` in the `Realtime Screen Text` panel.
- [ ] Leave the screen unchanged for at least three intervals.
- [ ] Confirm `samples` increases.
- [ ] Confirm `cached` stays at `1` after the first readable snapshot.
- [ ] Confirm `duplicates skipped` increases while the screen remains unchanged.
- [ ] Change visible text on the screen by switching tabs or opening a text-heavy document.
- [ ] Confirm `cached` increases by one.
- [ ] Confirm the sidebar `Realtime Screen Text Cache` shows the newest sample.
- [ ] Click `Stop`.
- [ ] Confirm the status says realtime screen text stopped.
- [ ] Click `Start` again.
- [ ] Confirm a new session starts with counters reset.
- [ ] Click `Stop` before quitting.

## Follow-Up Options

- Add a cache browser detail view that can inspect markdown and compact JSON for cached realtime snapshots.
- Add retention settings such as max age or max rows.
- Add user-configurable sample interval after the two-second default proves stable.
- Consider an `SCStream` frame source only after the sampled implementation is verified and OCR cadence limits are understood.

## Self-Review

Spec coverage:

- Realtime recording is covered by `RealtimeScreenTextPipeline`.
- Text caching is covered by `RealtimeScreenTextCache`.
- Frame-level OCR reuse is covered by `RealtimeScreenTextSampler` using `ScreenTextMemory`.
- Duplicate text persistence avoidance is covered by aggregate text/layout hashes.
- UI start/stop controls are covered by `ContentView`.
- Local-first privacy is preserved because only text and derived exports are cached.

Placeholder scan:

- The plan avoids placeholder steps and names exact files, exact commands, and exact code for the new types.

Type consistency:

- `RealtimeScreenTextSnapshot` feeds `RealtimeScreenTextSnapshotRecord`.
- `RealtimeScreenTextSampler.sample(sessionID:sequenceNumber:)` returns the snapshot consumed by `RealtimeScreenTextPipeline`.
- `ScreenTextHasher.hashAggregateText(_:)` and `hashAggregateLayout(_:)` are used by the sampler and smoke harness.
