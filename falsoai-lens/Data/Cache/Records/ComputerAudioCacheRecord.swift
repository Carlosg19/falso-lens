import Foundation
import GRDB

struct ComputerAudioCacheRecord: Codable, FetchableRecord, PersistableRecord, Identifiable, Equatable {
    static let databaseTableName = "computer_audio_cache"

    var id: Int64?
    var capturedAt: Date
    var sessionID: UUID
    var chunkID: String
    var sequenceNumber: Int
    var startTime: TimeInterval
    var endTime: TimeInterval
    var duration: TimeInterval
    var language: String?
    var text: String
    var segmentsJSON: String?
    var inferenceDurationSeconds: Double?
}
