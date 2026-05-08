import Foundation

extension CapturedAudioSource {
    nonisolated var displayName: String {
        switch self {
        case .computer:
            return "Computer"
        case .microphone:
            return "Microphone"
        }
    }
}
