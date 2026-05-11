import GRDB

enum AudioCacheMigrations {
    nonisolated static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("createAudioTranscriptCaches") { db in
            try createAudioCacheTable(named: "computer_audio_cache", in: db)
            try createAudioCacheTable(named: "microphone_audio_cache", in: db)
        }

        return migrator
    }

    nonisolated private static func createAudioCacheTable(named tableName: String, in db: Database) throws {
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
