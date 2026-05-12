import Foundation
import GRDB

struct ScreenTextRecord: Codable, FetchableRecord, PersistableRecord, Identifiable, Equatable {
    static let databaseTableName = "screen_text_captures"

    var id: Int64?
    var capturedAt: Date
    var source: String
    var recognizedText: String
    var characterCount: Int
}
