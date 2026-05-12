# Remove Manipulation Heuristics Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remove the local manipulation heuristic analyzer and leave the Vision path focused on capturing, saving, and displaying screen text.

**Architecture:** Keep `ScreenCaptureService` and `OCRService` intact because they are the text acquisition path. Replace the analysis-shaped `ScanPipeline`/`ScanStorage` model with a text-only screen text pipeline and data store, then delete analyzer-only symbols once call sites are gone. Do not delete the old on-disk `Scans.sqlite` file; simply stop writing to it so this change is non-destructive for user data.

**Tech Stack:** SwiftUI, ScreenCaptureKit, Vision, GRDB, macOS Application Support storage, `xcodebuild`.

---

## File Structure

Create:
- `falsoai-lens/Data/ScreenText/ScreenTextRecord.swift`: GRDB record for saved screen text.
- `falsoai-lens/Data/ScreenText/ScreenTextStorage.swift`: text-only persistence for OCR captures.

Modify:
- `falsoai-lens/Pipelines/Vision/Services/ScanPipeline.swift`: convert to a text-only pipeline, then rename to `ScreenTextPipeline.swift`.
- `falsoai-lens/ContentView.swift`: remove manipulation UI, wire screen text capture/storage UI.
- `falsoai-lens/Services/NotificationService.swift`: remove manipulation notification sending; keep notification permission request if the permission UI remains.

Delete after no references remain:
- `falsoai-lens/Services/LocalHeuristicAnalyzer.swift`
- `falsoai-lens/Services/ScanStorage.swift`

Keep unchanged:
- `falsoai-lens/Pipelines/Vision/Services/ScreenCaptureService.swift`
- `falsoai-lens/Pipelines/Vision/Services/OCRService.swift`
- `falsoai-lens/Services/PermissionManager.swift`

## Safety Checks

Before editing, confirm a clean worktree:

```bash
git status --short
```

Expected output: no files listed.

There is no test target configured in this repo. Use compile checks and symbol-removal checks after each task.

---

### Task 1: Add Text-Only Screen Text Storage

**Files:**
- Create: `falsoai-lens/Data/ScreenText/ScreenTextRecord.swift`
- Create: `falsoai-lens/Data/ScreenText/ScreenTextStorage.swift`

- [ ] **Step 1: Create the screen text record**

Create `falsoai-lens/Data/ScreenText/ScreenTextRecord.swift`:

```swift
import Foundation
import GRDB

struct ScreenTextRecord: Codable, FetchableRecord, PersistableRecord, Identifiable, Equatable {
    static let databaseTableName = "screen_text_captures"

    var id: Int64?
    var capturedAt: Date
    var source: String
    var recognizedText: String
    var characterCount: Int
}
```

- [ ] **Step 2: Create the screen text storage**

Create `falsoai-lens/Data/ScreenText/ScreenTextStorage.swift`:

```swift
import Foundation
import GRDB

@MainActor
final class ScreenTextStorage {
    private let dbQueue: DatabaseQueue

    init(databaseURL: URL) throws {
        dbQueue = try DatabaseQueue(path: databaseURL.path)
        try Self.migrator.migrate(dbQueue)
    }

    static func makeDefault() throws -> ScreenTextStorage {
        try ScreenTextStorage(databaseURL: defaultDatabaseURL())
    }

    static func makePreview() throws -> ScreenTextStorage {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("FalsoaiLensScreenText-\(UUID().uuidString).sqlite")
        return try ScreenTextStorage(databaseURL: url)
    }

    @discardableResult
    func save(_ record: ScreenTextRecord) throws -> ScreenTextRecord {
        try dbQueue.write { db in
            var mutableRecord = record
            try mutableRecord.insert(db)
            mutableRecord.id = db.lastInsertedRowID
            return mutableRecord
        }
    }

    func fetchRecent(limit: Int = 100) throws -> [ScreenTextRecord] {
        try dbQueue.read { db in
            try ScreenTextRecord.fetchAll(
                db,
                sql: "SELECT * FROM screen_text_captures ORDER BY capturedAt DESC LIMIT ?",
                arguments: [limit]
            )
        }
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
        return directoryURL.appendingPathComponent("ScreenText.sqlite")
    }

    private static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("createScreenTextCaptures") { db in
            try db.create(table: ScreenTextRecord.databaseTableName, ifNotExists: true) { table in
                table.autoIncrementedPrimaryKey("id")
                table.column("capturedAt", .datetime).notNull()
                table.column("source", .text).notNull()
                table.column("recognizedText", .text).notNull()
                table.column("characterCount", .integer).notNull()
            }

            try db.create(
                index: "idx_screen_text_captures_capturedAt",
                on: ScreenTextRecord.databaseTableName,
                columns: ["capturedAt"]
            )
        }

        return migrator
    }
}
```

- [ ] **Step 3: Build after adding storage**

Run:

```bash
xcodebuild -project falsoai-lens.xcodeproj -scheme falsoai-lens -configuration Debug build
```

Expected: `BUILD SUCCEEDED`.

- [ ] **Step 4: Commit**

```bash
git add falsoai-lens/Data/ScreenText/ScreenTextRecord.swift falsoai-lens/Data/ScreenText/ScreenTextStorage.swift
git commit -m "Add screen text storage"
```

---

### Task 2: Convert the Vision Pipeline to Text Capture Only

**Files:**
- Modify: `falsoai-lens/Pipelines/Vision/Services/ScanPipeline.swift`
- Rename after contents compile: `falsoai-lens/Pipelines/Vision/Services/ScanPipeline.swift` to `falsoai-lens/Pipelines/Vision/Services/ScreenTextPipeline.swift`

- [ ] **Step 1: Replace analysis-shaped pipeline code**

Replace the contents of `falsoai-lens/Pipelines/Vision/Services/ScanPipeline.swift` with:

```swift
import Combine
import CoreGraphics
import Foundation
import OSLog

@MainActor
final class ScreenTextPipeline: ObservableObject {
    @Published private(set) var latestCapture: ScreenTextRecord?
    @Published private(set) var recentCaptures: [ScreenTextRecord] = []
    @Published private(set) var lastOCRText = ""
    @Published private(set) var isCapturingScreen = false
    @Published private(set) var captureStatus = "Ready"
    @Published private(set) var errorMessage: String?

    private let ocrService = OCRService()
    private let screenCaptureService: ScreenCaptureService
    private let storage: ScreenTextStorage?
    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.falsoai.FalsoaiLens",
        category: "ScreenTextPipeline"
    )

    init(
        storage: ScreenTextStorage? = nil,
        screenCaptureService: ScreenCaptureService? = nil
    ) {
        self.storage = storage ?? (try? ScreenTextStorage.makeDefault())
        self.screenCaptureService = screenCaptureService ?? ScreenCaptureService()
        refreshRecentCaptures()
    }

    func captureScreenText() async {
        logger.info("Screen text capture started")
        isCapturingScreen = true
        errorMessage = nil
        captureStatus = "Checking screen recording permission"
        defer { isCapturingScreen = false }

        do {
            let image = try await screenCaptureService.captureMainDisplayImage()
            captureStatus = "Captured \(image.width) x \(image.height) image. Running OCR."

            let recognizedText = try ocrService.recognizeJoinedText(in: image)
            lastOCRText = recognizedText

            guard !recognizedText.isEmpty else {
                logger.warning("Screen text capture found no readable text")
                errorMessage = "No readable text found on the captured screen."
                captureStatus = "Capture succeeded, but OCR found no readable text."
                return
            }

            let savedRecord = try saveText(recognizedText, source: "Main Display")
            latestCapture = savedRecord
            captureStatus = "Screen text captured and saved."
            logger.info("Screen text capture completed characters=\(recognizedText.count, privacy: .public)")
        } catch {
            let message = Self.message(for: error)
            logger.error("Screen text capture failed: \(Self.errorLogDescription(for: error), privacy: .public)")
            errorMessage = message
            captureStatus = "Capture failed: \(message)"
        }
    }

    @discardableResult
    func saveText(_ text: String, source: String) throws -> ScreenTextRecord {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else {
            throw ScreenTextPipelineError.emptyText
        }

        let record = ScreenTextRecord(
            id: nil,
            capturedAt: Date(),
            source: source,
            recognizedText: trimmedText,
            characterCount: trimmedText.count
        )

        let savedRecord = try storage?.save(record) ?? record
        refreshRecentCaptures()
        return savedRecord
    }

    func refreshRecentCaptures() {
        recentCaptures = (try? storage?.fetchRecent(limit: 20)) ?? []
        logger.info("Refreshed recent screen text captures count=\(self.recentCaptures.count, privacy: .public)")
    }

    private static func message(for error: Error) -> String {
        let nsError = error as NSError

        if let recoverySuggestion = nsError.localizedRecoverySuggestion,
           !recoverySuggestion.isEmpty {
            return "\(nsError.localizedDescription) \(recoverySuggestion)"
        }

        return nsError.localizedDescription
    }

    private static func errorLogDescription(for error: Error) -> String {
        let nsError = error as NSError
        let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError
        let underlyingDescription = underlying.map {
            "underlyingDomain=\($0.domain), underlyingCode=\($0.code), underlyingDescription=\($0.localizedDescription)"
        } ?? "underlying=nil"
        let userInfoKeys = nsError.userInfo.keys
            .map { "\($0)" }
            .sorted()
            .joined(separator: ",")

        return [
            "type=\(type(of: error))",
            "domain=\(nsError.domain)",
            "code=\(nsError.code)",
            "description=\(nsError.localizedDescription)",
            "failureReason=\(nsError.localizedFailureReason ?? "nil")",
            "recoverySuggestion=\(nsError.localizedRecoverySuggestion ?? "nil")",
            underlyingDescription,
            "userInfoKeys=\(userInfoKeys.isEmpty ? "none" : userInfoKeys)"
        ].joined(separator: " | ")
    }
}

enum ScreenTextPipelineError: LocalizedError {
    case emptyText

    var errorDescription: String? {
        switch self {
        case .emptyText:
            return "No text was available to save."
        }
    }
}
```

- [ ] **Step 2: Rename the file**

Run:

```bash
git mv falsoai-lens/Pipelines/Vision/Services/ScanPipeline.swift falsoai-lens/Pipelines/Vision/Services/ScreenTextPipeline.swift
```

- [ ] **Step 3: Build to reveal call-site failures**

Run:

```bash
xcodebuild -project falsoai-lens.xcodeproj -scheme falsoai-lens -configuration Debug build
```

Expected: build fails because `ContentView` still references `ScanPipeline`, `ScanResult`, `recentScans`, `scan(text:)`, and `captureScreenOCRAndScan()`.

- [ ] **Step 4: Commit only after Task 3 makes the build pass**

Do not commit this task until `ContentView` is updated in Task 3.

---

### Task 3: Replace Manipulation UI With Screen Text UI

**Files:**
- Modify: `falsoai-lens/ContentView.swift`

- [ ] **Step 1: Replace the pipeline state object**

Change:

```swift
@StateObject private var pipeline = ScanPipeline()
```

To:

```swift
@StateObject private var screenText = ScreenTextPipeline()
```

- [ ] **Step 2: Replace recent scan sidebar section**

Replace the `Section("Recent Scans")` block with:

```swift
Section("Recent Screen Text") {
    if screenText.recentCaptures.isEmpty {
        Text("No screen text yet")
            .foregroundStyle(.secondary)
    } else {
        ForEach(screenText.recentCaptures) { capture in
            VStack(alignment: .leading, spacing: 4) {
                Text(capture.source)
                    .font(.headline)
                Text(capture.recognizedText)
                    .lineLimit(2)
                    .foregroundStyle(.secondary)
                Text("\(capture.characterCount) chars")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
        }
    }
}
```

- [ ] **Step 3: Replace toolbar refresh references**

Change:

```swift
pipeline.refreshRecentScans()
```

To:

```swift
screenText.refreshRecentCaptures()
```

- [ ] **Step 4: Replace the detail header and capture actions**

Replace the manipulation demo title/copy, `TextEditor`, `Run Demo Scan` button, and `Capture Screen + OCR` button with:

```swift
VStack(alignment: .leading, spacing: 4) {
    Text("Screen Text Capture")
        .font(.title)
    Text("Capture the main display and save recognized text locally.")
        .foregroundStyle(.secondary)
}

HStack {
    Button {
        Task { await screenText.captureScreenText() }
    } label: {
        Label(
            screenText.isCapturingScreen ? "Capturing" : "Capture Screen Text",
            systemImage: "text.viewfinder"
        )
    }
    .disabled(screenText.isCapturingScreen)

    Button("Request Screen Recording") {
        let granted = permissionManager.requestScreenRecordingPermission()
        lastPermissionAction = "Screen recording request returned \(granted). If you just granted access, quit and reopen the app."
        Task { await refreshPermissions() }
    }
}
```

- [ ] **Step 5: Replace status and last OCR references**

Change:

```swift
Text(pipeline.captureStatus)
```

To:

```swift
Text(screenText.captureStatus)
```

Change:

```swift
if !pipeline.lastOCRText.isEmpty {
```

To:

```swift
if !screenText.lastOCRText.isEmpty {
```

Inside that block, change both `pipeline.lastOCRText` references to `screenText.lastOCRText`.

- [ ] **Step 6: Replace error and remove analyzer result UI**

Change:

```swift
if let errorMessage = pipeline.errorMessage {
    Text(errorMessage)
        .foregroundStyle(.red)
}

if let result = pipeline.latestResult {
    resultView(result)
}
```

To:

```swift
if let errorMessage = screenText.errorMessage {
    Text(errorMessage)
        .foregroundStyle(.red)
}
```

Delete the whole `resultView(_ result: ScanResult) -> some View` function.

- [ ] **Step 7: Build after UI conversion**

Run:

```bash
xcodebuild -project falsoai-lens.xcodeproj -scheme falsoai-lens -configuration Debug build
```

Expected: build succeeds or fails only on leftover analyzer/storage references. Fix exact compiler errors by replacing `pipeline` with `screenText` only where the reference belongs to screen text capture.

- [ ] **Step 8: Commit Task 2 and Task 3 together**

```bash
git add falsoai-lens/Pipelines/Vision/Services/ScreenTextPipeline.swift falsoai-lens/ContentView.swift
git commit -m "Convert vision flow to screen text capture"
```

---

### Task 4: Delete Manipulation Heuristic Code

**Files:**
- Delete: `falsoai-lens/Services/LocalHeuristicAnalyzer.swift`
- Delete: `falsoai-lens/Services/ScanStorage.swift`
- Modify: `falsoai-lens/Services/NotificationService.swift`

- [ ] **Step 1: Remove manipulation notification method**

In `falsoai-lens/Services/NotificationService.swift`, replace the file contents with:

```swift
import Foundation
import UserNotifications

@MainActor
final class NotificationService {
    private let center: UNUserNotificationCenter

    init(center: UNUserNotificationCenter = .current()) {
        self.center = center
    }

    func requestAuthorization() async throws -> Bool {
        try await center.requestAuthorization(options: [.alert, .sound, .badge])
    }
}
```

- [ ] **Step 2: Delete analyzer and old scan storage**

Run:

```bash
git rm falsoai-lens/Services/LocalHeuristicAnalyzer.swift falsoai-lens/Services/ScanStorage.swift
```

- [ ] **Step 3: Verify analyzer symbols are gone**

Run:

```bash
rg -n "LocalHeuristicAnalyzer|AnalyzerResult|ScanResult|manipulationScore|analyzerSummary|evidenceJSON|sendManipulationDetectedNotification|Realtime Manipulation Demo|Run Demo Scan" falsoai-lens
```

Expected: no output.

- [ ] **Step 4: Verify text capture symbols remain**

Run:

```bash
rg -n "ScreenTextPipeline|ScreenTextStorage|ScreenTextRecord|captureScreenText|lastOCRText|VNRecognizeTextRequest|captureMainDisplayImage" falsoai-lens
```

Expected output includes:

```text
falsoai-lens/Data/ScreenText/ScreenTextRecord.swift
falsoai-lens/Data/ScreenText/ScreenTextStorage.swift
falsoai-lens/Pipelines/Vision/Services/ScreenTextPipeline.swift
falsoai-lens/Pipelines/Vision/Services/OCRService.swift
falsoai-lens/Pipelines/Vision/Services/ScreenCaptureService.swift
```

- [ ] **Step 5: Build**

Run:

```bash
xcodebuild -project falsoai-lens.xcodeproj -scheme falsoai-lens -configuration Debug build
```

Expected: `BUILD SUCCEEDED`.

- [ ] **Step 6: Commit**

```bash
git add falsoai-lens/Services/NotificationService.swift
git rm falsoai-lens/Services/LocalHeuristicAnalyzer.swift falsoai-lens/Services/ScanStorage.swift
git commit -m "Remove manipulation heuristics"
```

---

### Task 5: Manual Acceptance Check

**Files:**
- No source changes expected.

- [ ] **Step 1: Build**

Run:

```bash
xcodebuild -project falsoai-lens.xcodeproj -scheme falsoai-lens -configuration Debug build
```

Expected: `BUILD SUCCEEDED`.

- [ ] **Step 2: Launch from Xcode**

Open `falsoai-lens.xcodeproj`, run the `falsoai-lens` scheme, and grant Screen Recording permission if macOS requests it.

- [ ] **Step 3: Exercise screen text capture**

In the app:
- Click `Capture Screen Text`.
- Confirm `Last OCR Capture` appears with recognized text.
- Confirm `Recent Screen Text` shows the saved text in the sidebar.
- Confirm there is no manipulation score, evidence list, analyzer summary, or manipulation notification.

- [ ] **Step 4: Final symbol check**

Run:

```bash
rg -n "Manipulation|manipulation|Heuristic|AnalyzerResult|LocalHeuristicAnalyzer|ScanPipeline|ScanStorage|ScanResult" falsoai-lens
```

Expected: no output from app source. If `PermissionManager` or unrelated docs mention generic words, inspect the output and remove only app-source references tied to the deleted functionality.

---

## Self-Review

Spec coverage:
- Removes the local heuristic analyzer code.
- Removes manipulation scoring, evidence, summary, and notification sending from the runtime path.
- Keeps screen capture and OCR intact.
- Starts from text capture and text persistence, matching the audio cache/browser direction.

Risk controls:
- The existing `Scans.sqlite` database file is not deleted.
- The new text-only database uses a separate `ScreenText.sqlite` file.
- The plan compiles after each phase.
- Symbol checks verify analyzer code does not remain wired into app source.
