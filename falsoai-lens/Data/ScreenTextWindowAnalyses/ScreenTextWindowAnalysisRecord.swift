import Foundation
import GRDB

struct ScreenTextWindowAnalysisRecord: Codable, FetchableRecord, PersistableRecord, Identifiable, Equatable {
    static let databaseTableName = "screen_text_window_analyses"

    var id: Int64?
    var analysisID: UUID
    var windowID: UUID
    var sessionID: UUID
    var sequenceNumber: Int
    var windowStartedAt: Date
    var windowEndedAt: Date
    var generatedAt: Date
    var analyzerID: String
    var summaryMarkdown: String
    var encounterCount: Int
    var latencySeconds: Double
    var errorMessage: String?
}
