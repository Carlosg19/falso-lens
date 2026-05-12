import Foundation
import GRDB

final class ScreenTextWindowAnalysisDatabase {
    let dbQueue: DatabaseQueue

    nonisolated init(databaseURL: URL) throws {
        dbQueue = try DatabaseQueue(path: databaseURL.path)
        try ScreenTextWindowAnalysisMigrations.migrator.migrate(dbQueue)
    }

    nonisolated static func makeDefault() throws -> ScreenTextWindowAnalysisDatabase {
        try ScreenTextWindowAnalysisDatabase(databaseURL: defaultDatabaseURL())
    }

    nonisolated static func makePreview() throws -> ScreenTextWindowAnalysisDatabase {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("FalsoaiLensScreenTextWindowAnalyses-\(UUID().uuidString).sqlite")
        return try ScreenTextWindowAnalysisDatabase(databaseURL: url)
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

        return directoryURL.appendingPathComponent("ScreenTextWindowAnalyses.sqlite")
    }
}
