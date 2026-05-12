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
