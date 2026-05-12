import Foundation

struct ScreenTextWindow: Identifiable, Sendable, Equatable {
    let id: UUID
    let sessionID: UUID
    let sequenceNumber: Int
    let startedAt: Date
    let endedAt: Date
    let encounters: [ScreenTextEncounter]

    var durationSeconds: TimeInterval { endedAt.timeIntervalSince(startedAt) }
    var encounterCount: Int { encounters.count }
    var isEmpty: Bool { encounters.isEmpty }
}
