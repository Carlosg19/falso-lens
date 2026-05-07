import Foundation

struct TranscriptionResult: Sendable, Equatable {
    let text: String
    let segments: [TranscriptSegment]
    let language: String?
    let duration: TimeInterval?
}
