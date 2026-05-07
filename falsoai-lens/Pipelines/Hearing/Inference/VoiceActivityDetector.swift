import Foundation

nonisolated protocol VoiceActivityDetector: Sendable {
    func trimSilence(in audioFile: URL) async throws -> URL?
}

enum VoiceActivityError: LocalizedError, Equatable {
    case audioFileNotFound(URL)
    case unsupportedAudioFormat(sampleRate: Double, channelCount: UInt32)
    case decodeFailed(String)
    case encodeFailed(String)

    nonisolated var errorDescription: String? {
        switch self {
        case let .audioFileNotFound(url):
            return "Audio file does not exist at \(url.path)."
        case let .unsupportedAudioFormat(sampleRate, channelCount):
            return "Voice activity detection requires 16 kHz mono PCM WAV input. Got \(sampleRate) Hz / \(channelCount) channels."
        case let .decodeFailed(message):
            return "Voice activity detection could not decode the audio file. \(message)"
        case let .encodeFailed(message):
            return "Voice activity detection could not write the trimmed audio file. \(message)"
        }
    }

    nonisolated var recoverySuggestion: String? {
        switch self {
        case .audioFileNotFound:
            return "Pick a WAV file that exists, or check that audio normalization produced a file."
        case .unsupportedAudioFormat:
            return "Normalize the audio to 16 kHz mono PCM WAV before transcription."
        case .decodeFailed:
            return "Check that the WAV file is readable by AVFoundation."
        case .encodeFailed:
            return "Check that the app can write to its temporary directory."
        }
    }
}
