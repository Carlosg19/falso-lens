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
            elapsedSeconds: snapshot.elapsedSeconds,
            captureTargetKind: "allDisplays",
            captureApplicationName: nil,
            captureProcessID: nil,
            captureWindowTitle: nil
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

    func containsSnapshot(
        textHash: String,
        layoutHash: String
    ) throws -> Bool {
        try database.dbQueue.read { db in
            try Int.fetchOne(
                db,
                sql: """
                    SELECT 1
                    FROM realtime_screen_text_snapshots
                    WHERE aggregateTextHash = ?
                      AND aggregateLayoutHash = ?
                    LIMIT 1
                    """,
                arguments: [textHash, layoutHash]
            ) != nil
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
