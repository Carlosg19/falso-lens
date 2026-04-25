import Foundation
import GRDB
import UniformTypeIdentifiers

struct ScanRecord: Codable, FetchableRecord, PersistableRecord, Identifiable, Equatable {
    static let databaseTableName = "scans"

    var id: Int64?
    var capturedAt: Date
    var sourceApplication: String?
    var recognizedText: String
    var analyzerSummary: String?
    var manipulationScore: Double?
    var evidenceJSON: String?
}

@MainActor
final class ScanStorage {
    private let dbQueue: DatabaseQueue

    init(databaseURL: URL) throws {
        dbQueue = try DatabaseQueue(path: databaseURL.path)
        try Self.migrator.migrate(dbQueue)
    }

    static func makeDefault() throws -> ScanStorage {
        try ScanStorage(databaseURL: defaultDatabaseURL())
    }

    static func makePreview() throws -> ScanStorage {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("FalsoaiLensPreview-\(UUID().uuidString).sqlite")
        return try ScanStorage(databaseURL: url)
    }

    @discardableResult
    func save(_ record: ScanRecord) throws -> ScanRecord {
        try dbQueue.write { db in
            var mutableRecord = record
            try mutableRecord.insert(db)
            mutableRecord.id = db.lastInsertedRowID
            return mutableRecord
        }
    }

    func fetchRecent(limit: Int = 100) throws -> [ScanRecord] {
        try dbQueue.read { db in
            try ScanRecord.fetchAll(
                db,
                sql: "SELECT * FROM scans ORDER BY capturedAt DESC LIMIT ?",
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
        return directoryURL.appendingPathComponent("Scans.sqlite")
    }

    private static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("createScans") { db in
            try db.create(table: ScanRecord.databaseTableName, ifNotExists: true) { table in
                table.autoIncrementedPrimaryKey("id")
                table.column("capturedAt", .text).notNull()
                table.column("sourceApplication", .text)
                table.column("recognizedText", .text).notNull()
                table.column("analyzerSummary", .text)
                table.column("manipulationScore", .double)
                table.column("evidenceJSON", .text)
            }
        }

        return migrator
    }
}
