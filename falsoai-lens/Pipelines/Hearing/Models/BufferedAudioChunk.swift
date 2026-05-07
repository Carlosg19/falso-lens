import Foundation

struct BufferedAudioChunk: Sendable, Equatable {
    let sequenceNumber: Int
    let startFrame: Int64
    let samples: [Float]
    let sampleRate: Double
    let channelCount: Int
    let frameCount: Int

    var duration: TimeInterval {
        guard sampleRate > 0 else { return 0 }
        return Double(frameCount) / sampleRate
    }
}
