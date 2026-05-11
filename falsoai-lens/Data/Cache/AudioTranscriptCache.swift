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
