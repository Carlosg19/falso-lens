import Foundation

enum AudioChunkerError: LocalizedError, Equatable {
    case invalidConfiguration(chunkDuration: TimeInterval, overlapDuration: TimeInterval)

    var errorDescription: String? {
        switch self {
        case let .invalidConfiguration(chunkDuration, overlapDuration):
            return "Audio chunking configuration is invalid. Chunk duration \(chunkDuration)s must be greater than overlap \(overlapDuration)s, and overlap cannot be negative."
        }
    }
}

struct AudioChunkingConfiguration: Sendable, Equatable {
    var chunkDuration: TimeInterval
    var overlapDuration: TimeInterval

    nonisolated static let mvp = AudioChunkingConfiguration(
        chunkDuration: 5,
        overlapDuration: 1
    )

    nonisolated func validate() throws {
        guard chunkDuration > 0, overlapDuration >= 0, overlapDuration < chunkDuration else {
            throw AudioChunkerError.invalidConfiguration(
                chunkDuration: chunkDuration,
                overlapDuration: overlapDuration
            )
        }
    }
}
