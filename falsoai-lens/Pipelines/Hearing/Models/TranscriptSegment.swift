import Foundation

struct TranscriptSegment: Sendable, Equatable, Identifiable {
    let id: UUID
    let startTime: TimeInterval?
    let endTime: TimeInterval?
    let text: String

    nonisolated init(
        id: UUID = UUID(),
        startTime: TimeInterval?,
        endTime: TimeInterval?,
        text: String
    ) {
        self.id = id
        self.startTime = startTime
        self.endTime = endTime
        self.text = text
    }
}
