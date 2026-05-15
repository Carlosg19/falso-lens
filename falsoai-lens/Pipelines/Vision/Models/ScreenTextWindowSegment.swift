import CoreGraphics
import Foundation

struct ScreenTextWindowSegment: Identifiable, Equatable, Sendable {
    let id: String
    let displayID: UInt32
    let displayIndex: Int
    let role: ScreenTextStructureRole
    let boundsUnion: CGRect
    let text: String
    let lineCount: Int
    let totalSightingCount: Int
    let firstSightedAt: Date
    let lastSightedAt: Date
    let isRepeatedUI: Bool
}
