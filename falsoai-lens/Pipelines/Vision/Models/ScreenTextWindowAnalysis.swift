import Foundation

struct ScreenTextWindowAnalysis: Identifiable, Sendable, Equatable {
    let id: UUID
    let windowID: UUID
    let sessionID: UUID
    let sequenceNumber: Int
    let windowStartedAt: Date
    let windowEndedAt: Date
    let generatedAt: Date
    let analyzerID: String
    let summaryMarkdown: String
    let encounterCount: Int
    let latencySeconds: Double
    let errorMessage: String?
}
