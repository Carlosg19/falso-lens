import Foundation

struct DuplicateAnnotation: Sendable, Equatable, Identifiable, Codable {
    let chunkID: String
    let duplicateOfChunkID: String
    let confidence: Double
    let signals: [String]

    nonisolated var id: String { chunkID }

    nonisolated init(
        chunkID: String,
        duplicateOfChunkID: String,
        confidence: Double,
        signals: [String]
    ) {
        self.chunkID = chunkID
        self.duplicateOfChunkID = duplicateOfChunkID
        self.confidence = confidence
        self.signals = signals
    }

    enum CodingKeys: String, CodingKey {
        case chunkID = "chunk_id"
        case duplicateOfChunkID = "duplicate_of_chunk_id"
        case confidence
        case signals
    }
}
