import Foundation

protocol TranscriptionEngine: Sendable {
    func transcribe(
        audioFile: URL,
        mode: TranscriptionMode
    ) async throws -> TranscriptionResult
}
