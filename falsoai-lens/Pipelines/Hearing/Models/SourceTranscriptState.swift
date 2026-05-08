import Foundation

struct SourceTranscriptState: Sendable, Equatable {
    let source: CapturedAudioSource
    var text = ""
    var chunks: [SourceTranscriptChunk] = []
    var chunksTranscribed = 0
    var latestLanguage: String?
    var lastInferenceDurationSeconds: Double?

    var isEmpty: Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
