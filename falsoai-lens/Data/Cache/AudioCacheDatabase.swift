import Foundation
import GRDB

final class AudioCacheDatabase {
    let dbQueue: DatabaseQueue

    nonisolated init(databaseURL: URL) throws {
        dbQueue = try DatabaseQueue(path: databaseURL.path)
        try AudioCacheMigrations.migrator.migrate(dbQueue)
    }

    nonisolated static func makeDefault() throws -> AudioCacheDatabase {
        try AudioCacheDatabase(databaseURL: defaultDatabaseURL())
    }

    nonisolated static func makePreview() throws -> AudioCacheDatabase {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("FalsoaiLensAudioCache-\(UUID().uuidString).sqlite")
        return try AudioCacheDatabase(databaseURL: url)
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

        return directoryURL.appendingPathComponent("AudioTranscriptCache.sqlite")
    }
}
