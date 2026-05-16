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
    @Published private(set) var recentEncounters: [ScreenTextEncounter] = []
    @Published private(set) var samplesCaptured = 0
    @Published private(set) var snapshotsCached = 0
    @Published private(set) var duplicateSamplesSkipped = 0
    @Published private(set) var lastAnalysis: ScreenTextWindowAnalysis?
    @Published private(set) var lastAnalysisError: String?
    @Published private(set) var windowsCompleted = 0
    @Published private(set) var currentWindowStartedAt: Date?
    @Published private(set) var latestWindow: ScreenTextWindow?
    @Published private(set) var recentAnalyses: [ScreenTextWindowAnalysisRecord] = []

    private let sampler: RealtimeScreenTextSampler
    private let cache: RealtimeScreenTextCache?
    private let analysisStorage: ScreenTextWindowAnalysisStorage?
    private let encounterMemory: ScreenTextEncounterMemory
    private let llmExporter: ScreenTextLLMExporter
    private let structureClassifier: any ScreenTextStructureClassifying
    private let segmentDocumentExporter: ScreenTextWindowSegmentDocumentExporter
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
    private let windowAnalyzer: any ScreenTextWindowAnalyzing
    private var windowTracker: ScreenTextWindowTracker
    private var windowSequenceNumber = 0
    private var windowAnalysisTasks: [Task<Void, Never>] = []

    init(
        sampler: RealtimeScreenTextSampler? = nil,
        cache: RealtimeScreenTextCache? = try? RealtimeScreenTextCache.makeDefault(),
        encounterMemory: ScreenTextEncounterMemory = ScreenTextEncounterMemory(),
        llmExporter: ScreenTextLLMExporter = ScreenTextLLMExporter(),
        structureClassifier: any ScreenTextStructureClassifying = HeuristicScreenTextStructureClassifier(),
        segmentDocumentExporter: ScreenTextWindowSegmentDocumentExporter = ScreenTextWindowSegmentDocumentExporter(),
        sampleIntervalSeconds: TimeInterval = 1,
        windowAnalyzer: any ScreenTextWindowAnalyzing = StubScreenTextWindowAnalyzer(),
        windowSeconds: TimeInterval = 60,
        analysisStorage: ScreenTextWindowAnalysisStorage? = try? ScreenTextWindowAnalysisStorage.makeDefault()
    ) {
        self.sampler = sampler ?? RealtimeScreenTextSampler()
        self.cache = cache
        self.encounterMemory = encounterMemory
        self.llmExporter = llmExporter
        self.structureClassifier = structureClassifier
        self.segmentDocumentExporter = segmentDocumentExporter
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
            HeuristicScreenTextStructureClassifier.runSmokeChecks()
            ScreenTextWindowSegmentReducer.runSmokeChecks()
            try? ScreenTextWindowSegmentDocumentExporter.runSmokeChecks()
            await StubScreenTextWindowAnalyzer.runSmokeChecks()
            await ScreenTextWindowAnalysisStorage.runSmokeChecks()
        }
        #endif
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
        recentEncounters = []
        errorMessage = nil
        windowSequenceNumber = 0
        windowsCompleted = 0
        lastAnalysis = nil
        lastAnalysisError = nil
        latestWindow = nil
        windowTracker.start(referenceDate: Date())
        currentWindowStartedAt = windowTracker.currentWindowStartedAt
        isRunning = true
        statusText = "Realtime screen text is starting..."

        captureTask = Task { [weak self] in
            await self?.encounterMemory.clear()
            await self?.runLoop()
        }
    }

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
                latestWindow = nil
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
                recentEncounters = await encounterMemory.recentEncounters(referenceDate: snapshot.capturedAt)
                statusText = "Screen sample \(sequenceNumber) had no readable text."
                await sealAndFlushWindow(at: snapshot.capturedAt)
                return
            }

            let encounterSummary = await ingestEncounters(from: snapshot)

            guard try await shouldCache(snapshot) else {
                duplicateSamplesSkipped += 1
                statusText = "Screen text already cached; \(encounterSummary.totalEncounterCount) unique lines remain in one-minute memory."
                await sealAndFlushWindow(at: snapshot.capturedAt)
                return
            }

            try await cache?.save(snapshot)
            lastCachedTextHash = snapshot.aggregateTextHash
            lastCachedLayoutHash = snapshot.aggregateLayoutHash
            snapshotsCached += 1
            refreshRecentSnapshots()
            statusText = "Cached all-screen sample \(sequenceNumber); \(encounterSummary.totalEncounterCount) unique lines in one-minute memory."

            await sealAndFlushWindow(at: snapshot.capturedAt)
        } catch {
            errorMessage = Self.userFacingMessage(for: error)
            statusText = "Realtime screen text sample failed."
            logger.error("Realtime screen text sample failed: \(String(describing: error), privacy: .public)")
        }
    }

    private func ingestEncounters(from snapshot: RealtimeScreenTextSnapshot) async -> ScreenTextEncounterSummary {
        let llmDocument = llmExporter.export(snapshot.document)
        let classifiedDocument = structureClassifier.classify(llmDocument)
        let summary = await encounterMemory.ingest(snapshot, classifiedDocument: classifiedDocument)
        recentEncounters = await encounterMemory.recentEncounters(referenceDate: snapshot.capturedAt)
        return summary
    }

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
        latestWindow = window
        let segmentDocument = segmentDocumentExporter.export(window)

        currentWindowStartedAt = windowTracker.currentWindowStartedAt
        statusText = "Window \(sequenceNumber) sealed (\(encounters.count) lines); analyzing..."
        logger.info("Sealing window sequence=\(sequenceNumber, privacy: .public), encounters=\(encounters.count, privacy: .public)")
        logDebugSegmentDocument(segmentDocument)

        let analyzer = self.windowAnalyzer
        let task = Task { [weak self] in
            guard !Task.isCancelled else { return }
            do {
                let analysis = try await analyzer.analyze(segmentDocument)
                await self?.handleAnalysisCompleted(analysis)
            } catch {
                await self?.handleAnalysisFailed(error: error, window: window)
            }
        }
        windowAnalysisTasks.append(task)
    }

    private func logDebugSegmentDocument(_ document: ScreenTextWindowSegmentDocument) {
        let json: String
        do {
            json = try segmentDocumentExporter.compactJSON(document)
        } catch {
            json = "{\"error\":\"failed to encode segment document: \(error.localizedDescription)\"}"
        }

        let output = """

        ===== ScreenTextWindow SegmentDocument JSON BEGIN =====
        \(json)
        ===== ScreenTextWindow SegmentDocument JSON END =====

        """
        FileHandle.standardError.write(Data(output.utf8))
    }

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

    private func handleAnalysisFailed(error: Error, window: ScreenTextWindow) {
        lastAnalysisError = Self.userFacingMessage(for: error)
        statusText = "Window \(window.sequenceNumber) analysis failed."
        logger.error("Window analysis failed sequence=\(window.sequenceNumber, privacy: .public), error=\(String(describing: error), privacy: .public)")
    }

    private func recordAnalysisStorageError(_ error: Error) {
        lastAnalysisError = Self.userFacingMessage(for: error)
        logger.error("Persisting analysis failed: \(String(describing: error), privacy: .public)")
    }

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

    private nonisolated static func userFacingMessage(for error: Error) -> String {
        if let localizedError = error as? LocalizedError {
            let message = localizedError.errorDescription ?? error.localizedDescription
            let suggestion = localizedError.recoverySuggestion ?? ""
            return suggestion.isEmpty ? message : "\(message) \(suggestion)"
        }

        return error.localizedDescription
    }
}
