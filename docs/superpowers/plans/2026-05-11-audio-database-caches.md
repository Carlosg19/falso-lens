# Audio Database Caches Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add two local SQLite/GRDB transcript caches: one for computer-audio transcript chunks and one for microphone transcript chunks.

**Architecture:** Keep this as a narrow Data/Cache layer. `LiveAudioTranscriptionPipeline` writes successful live transcript chunks into `AudioTranscriptCache`; screen/OCR scan persistence remains in `ScanStorage`, and file transcription remains uncached.

**Tech Stack:** Swift, SwiftUI `@MainActor` pipelines, GRDB, SQLite, existing `SourceTranscriptChunk` / `SourceTranscriptSegment` models.

---

## File Structure

- Create: `falsoai-lens/Data/Cache/AudioCacheDatabase.swift`
  - Owns the GRDB `DatabaseQueue`, default cache database path, and migration execution.
- Create: `falsoai-lens/Data/Cache/AudioCacheMigrations.swift`
  - Creates `computer_audio_cache` and `microphone_audio_cache`.
- Create: `falsoai-lens/Data/Cache/Records/ComputerAudioCacheRecord.swift`
  - GRDB row type for computer-audio transcript chunks.
- Create: `falsoai-lens/Data/Cache/Records/MicrophoneAudioCacheRecord.swift`
  - GRDB row type for microphone transcript chunks.
- Create: `falsoai-lens/Data/Cache/AudioTranscriptCache.swift`
  - Async actor facade used by live audio pipelines.
- Create: `falsoai-lens/Data/Cache/AudioTranscriptCacheSmokeChecks.swift`
  - DEBUG-only smoke check because the project has no test target yet.
- Modify: `falsoai-lens/Pipelines/Hearing/Services/LiveAudioTranscriptionPipeline.swift`
  - Inject the cache, create a new cache session per start, save successful chunks without blocking transcription.
- Modify: `falsoai-lens/Pipelines/Hearing/Services/FileTranscriptionPipeline.swift`
  - Invoke the DEBUG smoke check next to existing parser/VAD/live-state smoke checks.

## Meta-Analysis

- The user wants a database cache, not canonical transcript history.
- The root pressure is live transcript chunks currently live only in memory; cache writes should not change capture, inference, duplicate detection, or screen scan persistence.
- A cache failure must not stop transcription or alter `errorMessage`; it should be logged only.
- Chunk IDs currently restart per source, so cache rows need a `sessionID` to distinguish separate listening sessions.
- Verification is limited to debug smoke checks and `xcodebuild ... build` because there is no configured test target.

---

### Task 1: Add Audio Cache Database and Migrations

**Files:**
- Create: `falsoai-lens/Data/Cache/AudioCacheDatabase.swift`
- Create: `falsoai-lens/Data/Cache/AudioCacheMigrations.swift`

- [ ] **Step 1: Create the cache database wrapper**

Add `falsoai-lens/Data/Cache/AudioCacheDatabase.swift`:

```swift
import Foundation
import GRDB

final class AudioCacheDatabase {
    let dbQueue: DatabaseQueue

    init(databaseURL: URL) throws {
        dbQueue = try DatabaseQueue(path: databaseURL.path)
        try AudioCacheMigrations.migrator.migrate(dbQueue)
    }

    static func makeDefault() throws -> AudioCacheDatabase {
        try AudioCacheDatabase(databaseURL: defaultDatabaseURL())
    }

    static func makePreview() throws -> AudioCacheDatabase {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("FalsoaiLensAudioCache-\(UUID().uuidString).sqlite")
        return try AudioCacheDatabase(databaseURL: url)
    }

    private static func defaultDatabaseURL() throws -> URL {
        let baseURL = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )

        let directoryURL = baseURL.appendingPathComponent("FalsoaiLens", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)

        return directoryURL.appendingPathComponent("AudioTranscriptCache.sqlite")
    }
}
```

- [ ] **Step 2: Create migrations for both cache tables**

Add `falsoai-lens/Data/Cache/AudioCacheMigrations.swift`:

```swift
import GRDB

enum AudioCacheMigrations {
    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("createAudioTranscriptCaches") { db in
            try createAudioCacheTable(named: "computer_audio_cache", in: db)
            try createAudioCacheTable(named: "microphone_audio_cache", in: db)
        }

        return migrator
    }

    private static func createAudioCacheTable(named tableName: String, in db: Database) throws {
        try db.create(table: tableName, ifNotExists: true) { table in
            table.autoIncrementedPrimaryKey("id")
            table.column("capturedAt", .text).notNull()
            table.column("sessionID", .text).notNull()
            table.column("chunkID", .text).notNull()
            table.column("sequenceNumber", .integer).notNull()
            table.column("startTime", .double).notNull()
            table.column("endTime", .double).notNull()
            table.column("duration", .double).notNull()
            table.column("language", .text)
            table.column("text", .text).notNull()
            table.column("segmentsJSON", .text)
            table.column("inferenceDurationSeconds", .double)
            table.uniqueKey(["sessionID", "chunkID"])
        }

        try db.create(index: "\(tableName)_capturedAt", on: tableName, columns: ["capturedAt"])
        try db.create(index: "\(tableName)_sessionID_sequenceNumber", on: tableName, columns: ["sessionID", "sequenceNumber"])
    }
}
```

- [ ] **Step 3: Verify the project still builds far enough to compile the new files**

Run:

```bash
xcodebuild -project falsoai-lens.xcodeproj -scheme falsoai-lens -configuration Debug build
```

Expected: the build may still fail later because record/cache facade files are not present yet only if later tasks are partially applied. If only Task 1 is applied, expected result is `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Commit Task 1**

```bash
git add falsoai-lens/Data/Cache/AudioCacheDatabase.swift falsoai-lens/Data/Cache/AudioCacheMigrations.swift
git commit -m "feat: add audio cache database schema"
```

---

### Task 2: Add GRDB Record Types

**Files:**
- Create: `falsoai-lens/Data/Cache/Records/ComputerAudioCacheRecord.swift`
- Create: `falsoai-lens/Data/Cache/Records/MicrophoneAudioCacheRecord.swift`

- [ ] **Step 1: Add the computer audio cache row type**

Add `falsoai-lens/Data/Cache/Records/ComputerAudioCacheRecord.swift`:

```swift
import Foundation
import GRDB

struct ComputerAudioCacheRecord: Codable, FetchableRecord, PersistableRecord, Identifiable, Equatable {
    static let databaseTableName = "computer_audio_cache"

    var id: Int64?
    var capturedAt: Date
    var sessionID: UUID
    var chunkID: String
    var sequenceNumber: Int
    var startTime: TimeInterval
    var endTime: TimeInterval
    var duration: TimeInterval
    var language: String?
    var text: String
    var segmentsJSON: String?
    var inferenceDurationSeconds: Double?
}
```

- [ ] **Step 2: Add the microphone audio cache row type**

Add `falsoai-lens/Data/Cache/Records/MicrophoneAudioCacheRecord.swift`:

```swift
import Foundation
import GRDB

struct MicrophoneAudioCacheRecord: Codable, FetchableRecord, PersistableRecord, Identifiable, Equatable {
    static let databaseTableName = "microphone_audio_cache"

    var id: Int64?
    var capturedAt: Date
    var sessionID: UUID
    var chunkID: String
    var sequenceNumber: Int
    var startTime: TimeInterval
    var endTime: TimeInterval
    var duration: TimeInterval
    var language: String?
    var text: String
    var segmentsJSON: String?
    var inferenceDurationSeconds: Double?
}
```

- [ ] **Step 3: Build**

Run:

```bash
xcodebuild -project falsoai-lens.xcodeproj -scheme falsoai-lens -configuration Debug build
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Commit Task 2**

```bash
git add falsoai-lens/Data/Cache/Records/ComputerAudioCacheRecord.swift falsoai-lens/Data/Cache/Records/MicrophoneAudioCacheRecord.swift
git commit -m "feat: add audio cache records"
```

---

### Task 3: Add AudioTranscriptCache Facade

**Files:**
- Create: `falsoai-lens/Data/Cache/AudioTranscriptCache.swift`

- [ ] **Step 1: Add the actor facade**

Add `falsoai-lens/Data/Cache/AudioTranscriptCache.swift`:

```swift
import Foundation
import GRDB

actor AudioTranscriptCache {
    private let database: AudioCacheDatabase

    init(database: AudioCacheDatabase) {
        self.database = database
    }

    static func makeDefault() throws -> AudioTranscriptCache {
        try AudioTranscriptCache(database: .makeDefault())
    }

    static func makePreview() throws -> AudioTranscriptCache {
        try AudioTranscriptCache(database: .makePreview())
    }

    @discardableResult
    func saveComputerChunk(
        _ chunk: SourceTranscriptChunk,
        sessionID: UUID,
        inferenceDurationSeconds: Double?
    ) throws -> ComputerAudioCacheRecord {
        let record = ComputerAudioCacheRecord(
            id: nil,
            capturedAt: Date(),
            sessionID: sessionID,
            chunkID: chunk.chunkID,
            sequenceNumber: chunk.sequenceNumber,
            startTime: chunk.startTime,
            endTime: chunk.endTime,
            duration: chunk.duration,
            language: chunk.language,
            text: chunk.text,
            segmentsJSON: try Self.segmentsJSON(from: chunk.segments),
            inferenceDurationSeconds: inferenceDurationSeconds
        )

        return try database.dbQueue.write { db in
            var mutableRecord = record
            try mutableRecord.insert(db)
            mutableRecord.id = db.lastInsertedRowID
            return mutableRecord
        }
    }

    @discardableResult
    func saveMicrophoneChunk(
        _ chunk: SourceTranscriptChunk,
        sessionID: UUID,
        inferenceDurationSeconds: Double?
    ) throws -> MicrophoneAudioCacheRecord {
        let record = MicrophoneAudioCacheRecord(
            id: nil,
            capturedAt: Date(),
            sessionID: sessionID,
            chunkID: chunk.chunkID,
            sequenceNumber: chunk.sequenceNumber,
            startTime: chunk.startTime,
            endTime: chunk.endTime,
            duration: chunk.duration,
            language: chunk.language,
            text: chunk.text,
            segmentsJSON: try Self.segmentsJSON(from: chunk.segments),
            inferenceDurationSeconds: inferenceDurationSeconds
        )

        return try database.dbQueue.write { db in
            var mutableRecord = record
            try mutableRecord.insert(db)
            mutableRecord.id = db.lastInsertedRowID
            return mutableRecord
        }
    }

    func fetchRecentComputerChunks(limit: Int = 100) throws -> [ComputerAudioCacheRecord] {
        try database.dbQueue.read { db in
            try ComputerAudioCacheRecord.fetchAll(
                db,
                sql: """
                    SELECT *
                    FROM computer_audio_cache
                    ORDER BY capturedAt DESC, id DESC
                    LIMIT ?
                    """,
                arguments: [limit]
            )
        }
    }

    func fetchRecentMicrophoneChunks(limit: Int = 100) throws -> [MicrophoneAudioCacheRecord] {
        try database.dbQueue.read { db in
            try MicrophoneAudioCacheRecord.fetchAll(
                db,
                sql: """
                    SELECT *
                    FROM microphone_audio_cache
                    ORDER BY capturedAt DESC, id DESC
                    LIMIT ?
                    """,
                arguments: [limit]
            )
        }
    }

    func clearComputerCache() throws {
        try database.dbQueue.write { db in
            try db.execute(sql: "DELETE FROM computer_audio_cache")
        }
    }

    func clearMicrophoneCache() throws {
        try database.dbQueue.write { db in
            try db.execute(sql: "DELETE FROM microphone_audio_cache")
        }
    }

    func clearAll() throws {
        try database.dbQueue.write { db in
            try db.execute(sql: "DELETE FROM computer_audio_cache")
            try db.execute(sql: "DELETE FROM microphone_audio_cache")
        }
    }

    func pruneOlderThan(_ cutoff: Date) throws {
        try database.dbQueue.write { db in
            try db.execute(
                sql: "DELETE FROM computer_audio_cache WHERE capturedAt < ?",
                arguments: [cutoff]
            )
            try db.execute(
                sql: "DELETE FROM microphone_audio_cache WHERE capturedAt < ?",
                arguments: [cutoff]
            )
        }
    }

    private static func segmentsJSON(from segments: [SourceTranscriptSegment]) throws -> String? {
        guard !segments.isEmpty else { return nil }
        let data = try JSONEncoder().encode(segments)
        return String(decoding: data, as: UTF8.self)
    }
}
```

- [ ] **Step 2: Build**

Run:

```bash
xcodebuild -project falsoai-lens.xcodeproj -scheme falsoai-lens -configuration Debug build
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Commit Task 3**

```bash
git add falsoai-lens/Data/Cache/AudioTranscriptCache.swift
git commit -m "feat: add audio transcript cache facade"
```

---

### Task 4: Add DEBUG Smoke Checks

**Files:**
- Create: `falsoai-lens/Data/Cache/AudioTranscriptCacheSmokeChecks.swift`
- Modify: `falsoai-lens/Pipelines/Hearing/Services/FileTranscriptionPipeline.swift`

- [ ] **Step 1: Add a smoke check for save/fetch/clear**

Add `falsoai-lens/Data/Cache/AudioTranscriptCacheSmokeChecks.swift`:

```swift
import Foundation
import OSLog

#if DEBUG
extension AudioTranscriptCache {
    static func runCacheSmokeCheck() {
        Task {
            let logger = Logger(
                subsystem: Bundle.main.bundleIdentifier ?? "com.falsoai.FalsoaiLens",
                category: "AudioTranscriptCacheSmokeCheck"
            )

            do {
                let cache = try AudioTranscriptCache.makePreview()
                let sessionID = UUID()
                let computerChunk = SourceTranscriptChunk(
                    chunkID: "computer_001",
                    source: .computer,
                    sequenceNumber: 1,
                    startTime: 0,
                    endTime: 5,
                    duration: 5,
                    language: "en",
                    text: "Computer cache smoke check",
                    segments: [
                        SourceTranscriptSegment(
                            startTime: 0,
                            endTime: 2,
                            text: "Computer cache smoke check"
                        )
                    ]
                )
                let microphoneChunk = SourceTranscriptChunk(
                    chunkID: "microphone_001",
                    source: .microphone,
                    sequenceNumber: 1,
                    startTime: 0,
                    endTime: 5,
                    duration: 5,
                    language: "en",
                    text: "Microphone cache smoke check",
                    segments: [
                        SourceTranscriptSegment(
                            startTime: 0,
                            endTime: 2,
                            text: "Microphone cache smoke check"
                        )
                    ]
                )

                try await cache.clearAll()
                try await cache.saveComputerChunk(
                    computerChunk,
                    sessionID: sessionID,
                    inferenceDurationSeconds: 0.12
                )
                try await cache.saveMicrophoneChunk(
                    microphoneChunk,
                    sessionID: sessionID,
                    inferenceDurationSeconds: 0.15
                )

                let computerRows = try await cache.fetchRecentComputerChunks(limit: 10)
                let microphoneRows = try await cache.fetchRecentMicrophoneChunks(limit: 10)

                assert(computerRows.count == 1, "Expected one computer cache row")
                assert(microphoneRows.count == 1, "Expected one microphone cache row")
                assert(computerRows.first?.text == computerChunk.text, "Expected computer cache text to round-trip")
                assert(microphoneRows.first?.text == microphoneChunk.text, "Expected microphone cache text to round-trip")

                logger.info("Audio transcript cache smoke check passed")
            } catch {
                assertionFailure("Audio transcript cache smoke check failed: \(error)")
            }
        }
    }
}
#endif
```

- [ ] **Step 2: Invoke the smoke check**

In `falsoai-lens/Pipelines/Hearing/Services/FileTranscriptionPipeline.swift`, inside the existing `#if DEBUG` block in `init(engine:)`, add this line after `LiveAudioTranscriptionPipeline.runStateSmokeCheck()`:

```swift
AudioTranscriptCache.runCacheSmokeCheck()
```

The DEBUG block should become:

```swift
#if DEBUG
WhisperOutputParser.runParserSmokeCheck()
RMSVoiceActivityDetector.runVADSmokeCheck()
TranscriptDuplicateAnalyzer.runDuplicateSmokeCheck()
LiveAudioTranscriptionPipeline.runStateSmokeCheck()
AudioTranscriptCache.runCacheSmokeCheck()
#endif
```

- [ ] **Step 3: Build**

Run:

```bash
xcodebuild -project falsoai-lens.xcodeproj -scheme falsoai-lens -configuration Debug build
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Commit Task 4**

```bash
git add falsoai-lens/Data/Cache/AudioTranscriptCacheSmokeChecks.swift falsoai-lens/Pipelines/Hearing/Services/FileTranscriptionPipeline.swift
git commit -m "test: add audio cache smoke check"
```

---

### Task 5: Wire the Cache into LiveAudioTranscriptionPipeline

**Files:**
- Modify: `falsoai-lens/Pipelines/Hearing/Services/LiveAudioTranscriptionPipeline.swift`

- [ ] **Step 1: Add cache properties**

Near the existing private properties, add:

```swift
private let audioCache: AudioTranscriptCache?
private var cacheSessionID = UUID()
```

- [ ] **Step 2: Update static constructors**

Change `computer()` to:

```swift
static func computer() -> LiveAudioTranscriptionPipeline {
    LiveAudioTranscriptionPipeline(
        source: .computer,
        captureProvider: ComputerAudioCaptureService(),
        audioCache: try? AudioTranscriptCache.makeDefault()
    )
}
```

Change `microphone()` to:

```swift
static func microphone() -> LiveAudioTranscriptionPipeline {
    LiveAudioTranscriptionPipeline(
        source: .microphone,
        captureProvider: MicrophoneAudioCaptureProvider(),
        audioCache: try? AudioTranscriptCache.makeDefault()
    )
}
```

- [ ] **Step 3: Update the initializer signature**

Change the initializer signature from:

```swift
init(
    source: CapturedAudioSource,
    captureProvider: (any LiveAudioCaptureProvider)? = nil,
    chunker: AudioChunker? = nil,
    normalizer: AudioNormalizer? = nil,
    engine: TranscriptionEngine? = nil,
    logger: Logger? = nil
)
```

to:

```swift
init(
    source: CapturedAudioSource,
    captureProvider: (any LiveAudioCaptureProvider)? = nil,
    chunker: AudioChunker? = nil,
    normalizer: AudioNormalizer? = nil,
    engine: TranscriptionEngine? = nil,
    audioCache: AudioTranscriptCache? = nil,
    logger: Logger? = nil
)
```

Inside the initializer body, after `self.captureProvider = ...`, add:

```swift
self.audioCache = audioCache
```

- [ ] **Step 4: Reset cache session on start**

Inside `func start(mode:)`, after `await chunker.clear()` and before `transcript = SourceTranscriptState(source: source)`, add:

```swift
cacheSessionID = UUID()
```

- [ ] **Step 5: Save successful chunks after appending to in-memory transcript**

In the private `append(...)` method, after the existing logger call that logs `"transcription appended characters=..."`, add:

```swift
saveTranscriptChunkToCache(
    transcriptChunk,
    inferenceDurationSeconds: elapsed
)
```

- [ ] **Step 6: Add a helper method that writes asynchronously**

Add this method near the other private helpers in `LiveAudioTranscriptionPipeline`:

```swift
private func saveTranscriptChunkToCache(
    _ chunk: SourceTranscriptChunk,
    inferenceDurationSeconds: Double?
) {
    guard let audioCache else { return }

    let sessionID = cacheSessionID
    let source = self.source
    let logger = self.logger

    Task {
        do {
            switch source {
            case .computer:
                try await audioCache.saveComputerChunk(
                    chunk,
                    sessionID: sessionID,
                    inferenceDurationSeconds: inferenceDurationSeconds
                )
            case .microphone:
                try await audioCache.saveMicrophoneChunk(
                    chunk,
                    sessionID: sessionID,
                    inferenceDurationSeconds: inferenceDurationSeconds
                )
            }
        } catch {
            logger.error("\(source.rawValue, privacy: .public) transcript cache save failed: \(String(describing: error), privacy: .public)")
        }
    }
}
```

- [ ] **Step 7: Build**

Run:

```bash
xcodebuild -project falsoai-lens.xcodeproj -scheme falsoai-lens -configuration Debug build
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 8: Commit Task 5**

```bash
git add falsoai-lens/Pipelines/Hearing/Services/LiveAudioTranscriptionPipeline.swift
git commit -m "feat: cache live audio transcript chunks"
```

---

### Task 6: Final Verification

**Files:**
- No file changes expected.

- [ ] **Step 1: Search for unintended screen-text cache additions**

Run:

```bash
rg -n "screen_text_cache|ScreenTextCache|saveScreen|screenText" falsoai-lens docs
```

Expected: no matches related to newly added screen-text cache code.

- [ ] **Step 2: Verify file transcription was not cached**

Run:

```bash
rg -n "AudioTranscriptCache|saveComputerChunk|saveMicrophoneChunk" falsoai-lens/Pipelines/Hearing/Services/FileTranscriptionPipeline.swift
```

Expected: only `AudioTranscriptCache.runCacheSmokeCheck()` appears in DEBUG setup; there should be no file transcription save path.

- [ ] **Step 3: Run the required build**

Run:

```bash
xcodebuild -project falsoai-lens.xcodeproj -scheme falsoai-lens -configuration Debug build
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Commit final verification note if any docs were adjusted**

If no docs or code changed during final verification, skip this commit.

---

## Self-Review

- Spec coverage: The plan creates exactly two audio caches, one table for computer audio and one table for microphone audio.
- Screen text exclusion: No `screen_text_cache` table or screen cache facade is introduced; `ScanStorage` remains the screen/OCR persistence path.
- File transcription exclusion: File transcription does not save transcript results to the cache.
- Type consistency: The plan uses existing `SourceTranscriptChunk`, `SourceTranscriptSegment`, and `CapturedAudioSource` names from the codebase.
- Verification: Each implementation task includes a build command; final verification checks the absence of screen-text cache code and file-transcription cache writes.
