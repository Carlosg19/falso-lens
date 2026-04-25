# Falsoai Lens Services Demo Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a simple native macOS demo that exercises permissions, analysis, persistence, and notifications through the starter services.

**Architecture:** Keep the demo local-first and deterministic. Add a small orchestration layer that accepts demo text, runs a local heuristic analyzer with optional localhost analyzer support later, saves the scan with GRDB, and updates a SwiftUI dashboard. ScreenCaptureKit is represented by permission/readiness checks in this demo; live frame capture remains a later increment.

**Tech Stack:** SwiftUI, SwiftData, GRDB, Vision, ScreenCaptureKit, AVFoundation, UserNotifications, AppKit, UniformTypeIdentifiers.

---

## File Structure

- Create `falsoai-lens/Services/DemoScanPipeline.swift`: coordinates scan input, analysis, persistence, and notifications.
- Create `falsoai-lens/Services/LocalHeuristicAnalyzer.swift`: offline manipulation-risk scoring for demo text.
- Modify `falsoai-lens/Services/AnalyzerService.swift`: expose localhost analyzer as optional future path, not required for demo success.
- Modify `falsoai-lens/Services/ScanStorage.swift`: add demo-friendly initializer and an inserted-record return value.
- Replace `falsoai-lens/ContentView.swift`: dashboard with permission status, text input, scan button, result panel, and recent scan list.
- Modify `falsoai-lens/falsoai_lensApp.swift`: prepare for menu-bar style commands and keep the main window.
- Verify `falsoai-lens.xcodeproj/project.pbxproj`: GRDB package and deployment target remain configured.

---

### Task 1: Add Local Heuristic Analyzer

**Files:**
- Create: `falsoai-lens/Services/LocalHeuristicAnalyzer.swift`

- [ ] **Step 1: Create a deterministic analyzer**

```swift
import Foundation

struct LocalHeuristicAnalyzer {
    func analyze(text: String) -> AnalyzerResult {
        let lowered = text.lowercased()
        let triggers = [
            "urgent",
            "limited time",
            "act now",
            "you must",
            "guaranteed",
            "secret",
            "they don't want you to know",
            "fear",
            "shocking"
        ]

        let hits = triggers.filter { lowered.contains($0) }
        let score = min(1.0, Double(hits.count) / 4.0)
        let summary: String

        if score >= 0.75 {
            summary = "High manipulation risk detected."
        } else if score >= 0.35 {
            summary = "Moderate manipulation risk detected."
        } else {
            summary = "Low manipulation risk detected."
        }

        return AnalyzerResult(
            summary: summary,
            manipulationScore: score,
            evidence: hits.isEmpty ? ["No high-pressure language matched."] : hits
        )
    }
}
```

- [ ] **Step 2: Build-check the new file**

Run:

```bash
xcodebuild -project falsoai-lens.xcodeproj -scheme falsoai-lens -configuration Debug build
```

Expected: build succeeds once full Xcode is selected.

---

### Task 2: Make Scan Storage Return Saved Records

**Files:**
- Modify: `falsoai-lens/Services/ScanStorage.swift`

- [ ] **Step 1: Change save API**

Replace:

```swift
func save(_ record: ScanRecord) throws {
    try dbQueue.write { db in
        try record.insert(db)
    }
}
```

With:

```swift
@discardableResult
func save(_ record: ScanRecord) throws -> ScanRecord {
    try dbQueue.write { db in
        var mutableRecord = record
        try mutableRecord.insert(db)
        mutableRecord.id = db.lastInsertedRowID
        return mutableRecord
    }
}
```

- [ ] **Step 2: Add preview storage factory**

Add inside `ScanStorage`:

```swift
static func makePreview() throws -> ScanStorage {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("FalsoaiLensPreview-\(UUID().uuidString).sqlite")
    return try ScanStorage(databaseURL: url)
}
```

- [ ] **Step 3: Build-check storage**

Run:

```bash
xcodebuild -project falsoai-lens.xcodeproj -scheme falsoai-lens -configuration Debug build
```

Expected: build succeeds once full Xcode is selected.

---

### Task 3: Add Demo Scan Pipeline

**Files:**
- Create: `falsoai-lens/Services/DemoScanPipeline.swift`

- [ ] **Step 1: Create pipeline state and scan flow**

```swift
import Foundation

struct DemoScanResult: Identifiable, Equatable {
    let id: UUID
    let text: String
    let analyzerResult: AnalyzerResult
    let savedRecord: ScanRecord?
}

@MainActor
final class DemoScanPipeline: ObservableObject {
    @Published private(set) var latestResult: DemoScanResult?
    @Published private(set) var recentScans: [ScanRecord] = []
    @Published private(set) var isScanning = false
    @Published private(set) var errorMessage: String?

    private let analyzer = LocalHeuristicAnalyzer()
    private let notificationService: NotificationService
    private let storage: ScanStorage?

    init(
        storage: ScanStorage? = try? .makeDefault(),
        notificationService: NotificationService = NotificationService()
    ) {
        self.storage = storage
        self.notificationService = notificationService
        refreshRecentScans()
    }

    func scan(text: String) async {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else {
            errorMessage = "Enter text to scan."
            return
        }

        isScanning = true
        errorMessage = nil
        defer { isScanning = false }

        let result = analyzer.analyze(text: trimmedText)
        let record = ScanRecord(
            id: nil,
            capturedAt: Date(),
            sourceApplication: "Demo Input",
            recognizedText: trimmedText,
            analyzerSummary: result.summary,
            manipulationScore: result.manipulationScore,
            evidenceJSON: String(data: (try? JSONEncoder().encode(result.evidence)) ?? Data(), encoding: .utf8)
        )

        let savedRecord: ScanRecord?
        do {
            savedRecord = try storage?.save(record)
            refreshRecentScans()
        } catch {
            savedRecord = nil
            errorMessage = error.localizedDescription
        }

        latestResult = DemoScanResult(
            id: UUID(),
            text: trimmedText,
            analyzerResult: result,
            savedRecord: savedRecord
        )

        if result.manipulationScore >= 0.75 {
            try? await notificationService.sendManipulationDetectedNotification(
                title: "Manipulation risk detected",
                body: result.summary
            )
        }
    }

    func refreshRecentScans() {
        recentScans = (try? storage?.fetchRecent(limit: 20)) ?? []
    }
}
```

- [ ] **Step 2: Build-check pipeline**

Run:

```bash
xcodebuild -project falsoai-lens.xcodeproj -scheme falsoai-lens -configuration Debug build
```

Expected: build succeeds once full Xcode is selected.

---

### Task 4: Replace Placeholder UI With Demo Dashboard

**Files:**
- Modify: `falsoai-lens/ContentView.swift`

- [ ] **Step 1: Replace scaffolded item list**

```swift
import SwiftUI
import SwiftData

struct ContentView: View {
    @StateObject private var pipeline = DemoScanPipeline()
    @State private var permissionSnapshot: PermissionSnapshot?
    @State private var demoText = "Limited time offer: act now before they hide the truth from you."
    private let permissionManager = PermissionManager()

    var body: some View {
        NavigationSplitView {
            List {
                Section("Permissions") {
                    permissionRow("Screen", permissionSnapshot?.screenRecording)
                    permissionRow("Accessibility", permissionSnapshot?.accessibility)
                    permissionRow("Notifications", permissionSnapshot?.notifications)
                    permissionRow("Microphone", permissionSnapshot?.microphone)
                }

                Section("Recent Scans") {
                    ForEach(pipeline.recentScans) { scan in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(scan.analyzerSummary ?? "Scan")
                                .font(.headline)
                            Text(scan.recognizedText)
                                .lineLimit(2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("Falsoai Lens")
            .toolbar {
                Button("Refresh") {
                    Task { await refreshPermissions() }
                    pipeline.refreshRecentScans()
                }
            }
        } detail: {
            VStack(alignment: .leading, spacing: 16) {
                Text("Realtime Manipulation Demo")
                    .font(.title)

                TextEditor(text: $demoText)
                    .font(.body)
                    .frame(minHeight: 140)
                    .border(.separator)

                HStack {
                    Button {
                        Task { await pipeline.scan(text: demoText) }
                    } label: {
                        Label(pipeline.isScanning ? "Scanning" : "Run Demo Scan", systemImage: "viewfinder")
                    }
                    .disabled(pipeline.isScanning)

                    Button("Request Screen Recording") {
                        _ = permissionManager.requestScreenRecordingPermission()
                    }
                }

                if let errorMessage = pipeline.errorMessage {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                }

                if let result = pipeline.latestResult {
                    resultView(result)
                }

                Spacer()
            }
            .padding()
        }
        .task {
            await refreshPermissions()
        }
    }

    private func refreshPermissions() async {
        permissionSnapshot = await permissionManager.currentSnapshot()
    }

    private func permissionRow(_ title: String, _ status: PermissionStatus?) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(label(for: status))
                .foregroundStyle(status == .authorized ? .green : .secondary)
        }
    }

    private func label(for status: PermissionStatus?) -> String {
        switch status {
        case .authorized:
            return "Allowed"
        case .denied:
            return "Denied"
        case .notDetermined:
            return "Needed"
        case .restricted:
            return "Restricted"
        case .unknown, nil:
            return "Unknown"
        }
    }

    private func resultView(_ result: DemoScanResult) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(result.analyzerResult.summary)
                .font(.headline)
            ProgressView(value: result.analyzerResult.manipulationScore)
            Text("Evidence: \(result.analyzerResult.evidence.joined(separator: ", "))")
                .foregroundStyle(.secondary)
        }
        .padding()
        .background(.thinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

#Preview {
    ContentView()
        .modelContainer(for: Item.self, inMemory: true)
}
```

- [ ] **Step 2: Build-check UI**

Run:

```bash
xcodebuild -project falsoai-lens.xcodeproj -scheme falsoai-lens -configuration Debug build
```

Expected: build succeeds once full Xcode is selected.

---

### Task 5: Prepare App Commands for Menu Bar Workflow

**Files:**
- Modify: `falsoai-lens/falsoai_lensApp.swift`

- [ ] **Step 1: Add commands for future scanning controls**

Add after `.modelContainer(sharedModelContainer)`:

```swift
.commands {
    CommandMenu("Falsoai Lens") {
        Button("Open Scanner") {
            NSApp.activate(ignoringOtherApps: true)
        }
        .keyboardShortcut("0", modifiers: [.command])
    }
}
```

- [ ] **Step 2: Import AppKit**

Add:

```swift
import AppKit
```

- [ ] **Step 3: Build-check app entry**

Run:

```bash
xcodebuild -project falsoai-lens.xcodeproj -scheme falsoai-lens -configuration Debug build
```

Expected: build succeeds once full Xcode is selected.

---

### Task 6: Manual Demo Verification

**Files:**
- Verify app behavior through Xcode run.

- [ ] **Step 1: Select full Xcode**

Run if needed:

```bash
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
```

Expected: `xcodebuild` uses full Xcode instead of Command Line Tools.

- [ ] **Step 2: Resolve Swift packages**

Run:

```bash
xcodebuild -resolvePackageDependencies -project falsoai-lens.xcodeproj -scheme falsoai-lens
```

Expected: GRDB resolves successfully.

- [ ] **Step 3: Build**

Run:

```bash
xcodebuild -project falsoai-lens.xcodeproj -scheme falsoai-lens -configuration Debug build
```

Expected: build succeeds.

- [ ] **Step 4: Run demo in Xcode**

Expected:
- Dashboard opens instead of placeholder item list.
- Permission statuses display.
- Demo text can be scanned.
- Result summary and score appear.
- Recent scan list updates after scan.
- High-risk sample text triggers a notification when notification permission is granted.

---

## Self-Review

- Spec coverage: demo exercises permissions, local analyzer, notification service, GRDB storage, SwiftUI app shell, and menu-bar preparation.
- Scope: live ScreenCaptureKit frame streaming and real Vision OCR from captured frames are intentionally deferred so the MVP demo remains simple and compilable.
- Verification: build requires full Xcode selected; current machine previously reported Command Line Tools as the active developer directory.
