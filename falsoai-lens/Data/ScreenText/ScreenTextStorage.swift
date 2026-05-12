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
