import Foundation

struct RealtimeScreenTextSnapshot: Identifiable, Equatable, Sendable {
    var id: String { "\(sessionID.uuidString)-\(sequenceNumber)" }

    let sessionID: UUID
    let sequenceNumber: Int
    let capturedAt: Date
    let document: MultiDisplayScreenTextDocument
    let recognizedText: String
    let markdownExport: String
    let compactJSONExport: String
    let chunkCount: Int
    let displayCount: Int
    let observationCount: Int
    let lineCount: Int
    let blockCount: Int
    let regionCount: Int
    let aggregateTextHash: String
    let aggregateLayoutHash: String
    let displayFrameHashes: [String]
    let reusedDisplayCount: Int
    let ocrDisplayCount: Int
    let elapsedSeconds: Double

    var hasReadableText: Bool {
        !recognizedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
