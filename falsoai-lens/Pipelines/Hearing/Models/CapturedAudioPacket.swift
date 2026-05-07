import Foundation

enum CapturedAudioSource: String, Sendable, Equatable {
    case computer
    case microphone
}

struct CapturedAudioPacket: Sendable, Equatable {
    let source: CapturedAudioSource
    let buffer: CapturedAudioBuffer
}
