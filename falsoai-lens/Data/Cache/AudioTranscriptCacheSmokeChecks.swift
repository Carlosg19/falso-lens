import Foundation
import OSLog

#if DEBUG
extension AudioTranscriptCache {
    static func runCacheSmokeCheck() {
        Task {
            let logger = Logger(
                subsystem: Bundle.main.bundleIdentifier ?? "com.falsoai.FalsoaiLens",
                category: "AudioTranscriptCacheSmokeCheck"
            )

            do {
                let cache = try AudioTranscriptCache.makePreview()
                let sessionID = UUID()
                let computerChunk = SourceTranscriptChunk(
                    chunkID: "computer_001",
                    source: .computer,
                    sequenceNumber: 1,
                    startTime: 0,
                    endTime: 5,
                    duration: 5,
                    language: "en",
                    text: "Computer cache smoke check",
                    segments: [
                        SourceTranscriptSegment(
                            startTime: 0,
                            endTime: 2,
                            text: "Computer cache smoke check"
                        )
                    ]
                )
                let microphoneChunk = SourceTranscriptChunk(
                    chunkID: "microphone_001",
                    source: .microphone,
                    sequenceNumber: 1,
                    startTime: 0,
                    endTime: 5,
                    duration: 5,
                    language: "en",
                    text: "Microphone cache smoke check",
                    segments: [
                        SourceTranscriptSegment(
                            startTime: 0,
                            endTime: 2,
                            text: "Microphone cache smoke check"
                        )
                    ]
                )

                try await cache.clearAll()
                try await cache.saveComputerChunk(
                    computerChunk,
                    sessionID: sessionID,
                    inferenceDurationSeconds: 0.12
                )
                try await cache.saveMicrophoneChunk(
                    microphoneChunk,
                    sessionID: sessionID,
                    inferenceDurationSeconds: 0.15
                )

                let computerRows = try await cache.fetchRecentComputerChunks(limit: 10)
                let microphoneRows = try await cache.fetchRecentMicrophoneChunks(limit: 10)

                assert(computerRows.count == 1, "Expected one computer cache row")
                assert(microphoneRows.count == 1, "Expected one microphone cache row")
                assert(computerRows.first?.text == computerChunk.text, "Expected computer cache text to round-trip")
                assert(microphoneRows.first?.text == microphoneChunk.text, "Expected microphone cache text to round-trip")

                logger.info("Audio transcript cache smoke check passed")
            } catch {
                assertionFailure("Audio transcript cache smoke check failed: \(error)")
            }
        }
    }
}
#endif
