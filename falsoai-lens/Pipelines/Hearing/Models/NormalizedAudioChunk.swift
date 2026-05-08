import Foundation

struct NormalizedAudioChunk: Sendable, Equatable {
    let source: CapturedAudioSource
    let sequenceNumber: Int
    let startFrame: Int64
    let samples: [Float]
    let sampleRate: Double
    let channelCount: Int
    let sourceSampleRate: Double
    let sourceChannelCount: Int
    let fileURL: URL?

    nonisolated var frameCount: Int {
        samples.count
    }

    nonisolated var duration: TimeInterval {
        guard sampleRate > 0 else { return 0 }
        return Double(frameCount) / sampleRate
    }

    nonisolated func withFileURL(_ fileURL: URL) -> NormalizedAudioChunk {
        NormalizedAudioChunk(
            source: source,
            sequenceNumber: sequenceNumber,
            startFrame: startFrame,
            samples: samples,
            sampleRate: sampleRate,
            channelCount: channelCount,
            sourceSampleRate: sourceSampleRate,
            sourceChannelCount: sourceChannelCount,
            fileURL: fileURL
        )
    }
}
