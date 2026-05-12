import CoreGraphics
import Foundation

struct ScreenTextEncounter: Identifiable, Equatable, Sendable {
    var id: String { normalizedTextHash }

    let text: String
    let normalizedTextHash: String
    let firstSeenAt: Date
    let lastSeenAt: Date
    let seenCount: Int
    let latestSource: ScreenTextEncounterSource
}

struct ScreenTextEncounterSource: Equatable, Sendable {
    let displayID: UInt32
    let displayIndex: Int
    let bounds: CGRect
}

struct ScreenTextEncounterSummary: Equatable, Sendable {
    let totalEncounterCount: Int
    let newEncounterCount: Int
    let updatedEncounterCount: Int
    let prunedEncounterCount: Int
}
