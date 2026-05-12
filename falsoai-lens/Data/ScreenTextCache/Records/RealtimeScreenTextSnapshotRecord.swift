import Foundation
import GRDB

struct RealtimeScreenTextSnapshotRecord: Codable, FetchableRecord, PersistableRecord, Identifiable, Equatable {
    static let databaseTableName = "realtime_screen_text_snapshots"

    var id: Int64?
    var capturedAt: Date
    var sessionID: UUID
    var sequenceNumber: Int
    var displayCount: Int
    var observationCount: Int
    var lineCount: Int
    var blockCount: Int
    var regionCount: Int
    var recognizedText: String
    var markdownExport: String
    var compactJSONExport: String
    var chunkCount: Int
    var aggregateTextHash: String
    var aggregateLayoutHash: String
    var displayFrameHashesJSON: String
    var reusedDisplayCount: Int
    var ocrDisplayCount: Int
    var elapsedSeconds: Double
    var captureTargetKind: String
    var captureApplicationName: String?
    var captureProcessID: Int32?
    var captureWindowTitle: String?
}
