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

    private let sampler: RealtimeScreenTextSampler
    private let cache: RealtimeScreenTextCache?
    private let encounterMemory: ScreenTextEncounterMemory
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
                await encounterMemory.clear()
                recentEncounters = []
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
                return
            }

            let encounterSummary = await ingestEncounters(from: snapshot)

            guard try await shouldCache(snapshot) else {
                duplicateSamplesSkipped += 1
                statusText = "Screen text already cached; \(encounterSummary.totalEncounterCount) unique lines remain in five-minute memory."
                return
            }

            try await cache?.save(snapshot)
            lastCachedTextHash = snapshot.aggregateTextHash
            lastCachedLayoutHash = snapshot.aggregateLayoutHash
            snapshotsCached += 1
            refreshRecentSnapshots()
            statusText = "Cached all-screen sample \(sequenceNumber); \(encounterSummary.totalEncounterCount) unique lines in five-minute memory."
        } catch {
            errorMessage = Self.userFacingMessage(for: error)
            statusText = "Realtime screen text sample failed."
            logger.error("Realtime screen text sample failed: \(String(describing: error), privacy: .public)")
        }
    }

    private func ingestEncounters(from snapshot: RealtimeScreenTextSnapshot) async -> ScreenTextEncounterSummary {
        let summary = await encounterMemory.ingest(snapshot)
        recentEncounters = await encounterMemory.recentEncounters(referenceDate: snapshot.capturedAt)
        return summary
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
