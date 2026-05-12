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

        migrator.registerMigration("addRealtimeScreenTextCaptureTargetMetadata") { db in
            try db.alter(table: RealtimeScreenTextSnapshotRecord.databaseTableName) { table in
                table.add(column: "captureTargetKind", .text)
                    .notNull()
                    .defaults(to: "allDisplays")
                table.add(column: "captureApplicationName", .text)
                table.add(column: "captureProcessID", .integer)
                table.add(column: "captureWindowTitle", .text)
            }
        }

        return migrator
    }
}
