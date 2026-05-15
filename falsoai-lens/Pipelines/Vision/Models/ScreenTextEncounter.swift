import CoreGraphics
import Foundation

struct ScreenTextEncounter: Identifiable, Equatable, Sendable {
    var id: String { "\(displayID)|\(normalizedTextHash)" }

    let text: String
    let normalizedTextHash: String
    let displayID: UInt32
    let displayIndex: Int
    let firstSeenAt: Date
    let lastSeenAt: Date
    let seenCount: Int
    let sightings: [ScreenTextEncounterSighting]
    let roleCounts: [ScreenTextStructureRole: Int]

    var latestSighting: ScreenTextEncounterSighting? { sightings.last }

    var dominantRole: ScreenTextStructureRole {
        guard let entry = roleCounts.max(by: { $0.value < $1.value }) else {
            return .unknown
        }
        return entry.key
    }
}

struct ScreenTextEncounterSighting: Equatable, Sendable {
    let bounds: CGRect
    let sightedAt: Date
    let role: ScreenTextStructureRole
    let blockAlias: String?
}

struct ScreenTextEncounterSummary: Equatable, Sendable {
    let totalEncounterCount: Int
    let newEncounterCount: Int
    let updatedEncounterCount: Int
    let prunedEncounterCount: Int
}
