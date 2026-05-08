import Foundation

struct LiveTranscriptChunkEvent: Sendable {
    let chunk: SourceTranscriptChunk
    let normalizedSamples: [Float]
    let normalizedSampleRate: Double

    nonisolated init(
        chunk: SourceTranscriptChunk,
        normalizedSamples: [Float],
        normalizedSampleRate: Double
    ) {
        self.chunk = chunk
        self.normalizedSamples = normalizedSamples
        self.normalizedSampleRate = normalizedSampleRate
    }
}
