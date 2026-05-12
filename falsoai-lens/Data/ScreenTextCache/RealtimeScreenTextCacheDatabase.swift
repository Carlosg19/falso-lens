import Foundation
import GRDB

final class RealtimeScreenTextCacheDatabase {
    let dbQueue: DatabaseQueue

    nonisolated init(databaseURL: URL) throws {
        dbQueue = try DatabaseQueue(path: databaseURL.path)
        try RealtimeScreenTextCacheMigrations.migrator.migrate(dbQueue)
    }

    nonisolated static func makeDefault() throws -> RealtimeScreenTextCacheDatabase {
        try RealtimeScreenTextCacheDatabase(databaseURL: defaultDatabaseURL())
    }

    nonisolated static func makePreview() throws -> RealtimeScreenTextCacheDatabase {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("FalsoaiLensRealtimeScreenTextCache-\(UUID().uuidString).sqlite")
        return try RealtimeScreenTextCacheDatabase(databaseURL: url)
    }

    nonisolated private static func defaultDatabaseURL() throws -> URL {
        let baseURL = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )

        let directoryURL = baseURL.appendingPathComponent("FalsoaiLens", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)

        return directoryURL.appendingPathComponent("RealtimeScreenTextCache.sqlite")
    }
}
