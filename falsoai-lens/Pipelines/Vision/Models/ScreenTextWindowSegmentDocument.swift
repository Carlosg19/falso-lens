import CoreGraphics
import Foundation

struct ScreenTextWindowSegmentDocument: Codable, Equatable, Sendable {
    let window: ScreenTextWindowMetadataDTO
    let segments: [ScreenTextWindowSegmentDTO]
}

struct ScreenTextWindowMetadataDTO: Codable, Equatable, Sendable {
    let id: UUID
    let sessionID: UUID
    let sequenceNumber: Int
    let startedAt: Date
    let endedAt: Date
    let durationSeconds: Double
    let displayCount: Int
    let encounterCount: Int
    let segmentCount: Int
}

struct ScreenTextWindowSegmentDTO: Codable, Equatable, Sendable {
    let id: String
    let displayID: UInt32
    let displayIndex: Int
    let role: ScreenTextStructureRole
    let bounds: ScreenTextWindowBoundsDTO
    let text: String
    let lineCount: Int
    let totalSightingCount: Int
    let firstSightedAt: Date
    let lastSightedAt: Date
    let isRepeatedUI: Bool
}

struct ScreenTextWindowBoundsDTO: Codable, Equatable, Sendable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double

    init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    init(_ rect: CGRect) {
        self.x = Double(rect.origin.x)
        self.y = Double(rect.origin.y)
        self.width = Double(rect.width)
        self.height = Double(rect.height)
    }
}
