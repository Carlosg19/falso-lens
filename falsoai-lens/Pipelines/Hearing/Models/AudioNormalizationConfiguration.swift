import Foundation

enum AudioNormalizationError: LocalizedError, Equatable {
    case invalidConfiguration(targetSampleRate: Double, targetChannelCount: Int)
    case invalidChunkFormat(sampleRate: Double, channelCount: Int, frameCount: Int)
    case invalidChunkLayout(expectedSamples: Int, actualSamples: Int)
    case wavDataTooLarge(sampleCount: Int)

    var errorDescription: String? {
        switch self {
        case let .invalidConfiguration(targetSampleRate, targetChannelCount):
            return "Audio normalization configuration is invalid. Target sample rate \(targetSampleRate) Hz must be positive and target channel count \(targetChannelCount) must be 1."
        case let .invalidChunkFormat(sampleRate, channelCount, frameCount):
            return "Audio chunk format is invalid. Sample rate \(sampleRate) Hz, channel count \(channelCount), and frame count \(frameCount) must all be positive."
        case let .invalidChunkLayout(expectedSamples, actualSamples):
            return "Audio chunk sample layout is invalid. Expected \(expectedSamples) samples, got \(actualSamples)."
        case let .wavDataTooLarge(sampleCount):
            return "Audio chunk has \(sampleCount) samples, which is too large to write as one PCM WAV file."
        }
    }
}

struct AudioNormalizationConfiguration: Sendable, Equatable {
    var targetSampleRate: Double
    var targetChannelCount: Int
    var outputDirectory: URL

    nonisolated static let whisperMVP = AudioNormalizationConfiguration(
        targetSampleRate: 16_000,
        targetChannelCount: 1,
        outputDirectory: URL(
            fileURLWithPath: NSTemporaryDirectory(),
            isDirectory: true
        ).appendingPathComponent("live-transcriber", isDirectory: true)
    )

    nonisolated func validate() throws {
        guard targetSampleRate > 0, targetChannelCount == 1 else {
            throw AudioNormalizationError.invalidConfiguration(
                targetSampleRate: targetSampleRate,
                targetChannelCount: targetChannelCount
            )
        }
    }
}
