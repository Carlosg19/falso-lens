import GRDB

enum ScreenTextWindowAnalysisMigrations {
    nonisolated static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("createScreenTextWindowAnalyses") { db in
            try db.create(table: ScreenTextWindowAnalysisRecord.databaseTableName, ifNotExists: true) { table in
                table.autoIncrementedPrimaryKey("id")
                table.column("analysisID", .text).notNull().unique()
                table.column("windowID", .text).notNull()
                table.column("sessionID", .text).notNull()
                table.column("sequenceNumber", .integer).notNull()
                table.column("windowStartedAt", .datetime).notNull()
                table.column("windowEndedAt", .datetime).notNull()
                table.column("generatedAt", .datetime).notNull()
                table.column("analyzerID", .text).notNull()
                table.column("summaryMarkdown", .text).notNull()
                table.column("encounterCount", .integer).notNull()
                table.column("latencySeconds", .double).notNull()
                table.column("errorMessage", .text)
            }

            try db.create(
                index: "screen_text_window_analyses_generatedAt",
                on: ScreenTextWindowAnalysisRecord.databaseTableName,
                columns: ["generatedAt"]
            )
            try db.create(
                index: "screen_text_window_analyses_session_sequence",
                on: ScreenTextWindowAnalysisRecord.databaseTableName,
                columns: ["sessionID", "sequenceNumber"]
            )
        }

        return migrator
    }
}
