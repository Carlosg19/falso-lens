import Foundation

enum CapturedAudioSource: String, Sendable, Equatable, Codable {
    case computer
    case microphone
}

struct CapturedAudioPacket: Sendable, Equatable {
    let source: CapturedAudioSource
    let buffer: CapturedAudioBuffer
}
