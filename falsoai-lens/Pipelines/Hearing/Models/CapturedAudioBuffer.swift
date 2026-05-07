import AVFoundation
import CoreMedia
import Foundation

struct CapturedAudioBuffer: Sendable, Equatable {
    let samples: [Float]
    let sampleRate: Double
    let channelCount: Int
    let frameCount: Int
    let hostTime: UInt64

    var duration: TimeInterval {
        guard sampleRate > 0 else { return 0 }
        return Double(frameCount) / sampleRate
    }

    nonisolated init(
        samples: [Float],
        sampleRate: Double,
        channelCount: Int,
        frameCount: Int,
        hostTime: UInt64
    ) {
        self.samples = samples
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.frameCount = frameCount
        self.hostTime = hostTime
    }

    nonisolated init(copying buffer: AVAudioPCMBuffer, at time: AVAudioTime) {
        let frameCount = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        var copiedSamples: [Float] = []
        copiedSamples.reserveCapacity(frameCount * max(channelCount, 1))

        if let channelData = buffer.floatChannelData {
            for frameIndex in 0..<frameCount {
                for channelIndex in 0..<channelCount {
                    copiedSamples.append(channelData[channelIndex][frameIndex])
                }
            }
        }

        self.init(
            samples: copiedSamples,
            sampleRate: buffer.format.sampleRate,
            channelCount: channelCount,
            frameCount: frameCount,
            hostTime: time.hostTime
        )
    }
}
