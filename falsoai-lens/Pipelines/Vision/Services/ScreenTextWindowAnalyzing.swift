import Foundation

protocol ScreenTextWindowAnalyzing: Sendable {
    var analyzerID: String { get }
    func analyze(_ document: ScreenTextWindowSegmentDocument) async throws -> ScreenTextWindowAnalysis
}
