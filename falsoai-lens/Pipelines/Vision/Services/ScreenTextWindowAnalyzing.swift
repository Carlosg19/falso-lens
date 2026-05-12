import Foundation

protocol ScreenTextWindowAnalyzing: Sendable {
    var analyzerID: String { get }
    func analyze(_ window: ScreenTextWindow) async throws -> ScreenTextWindowAnalysis
}
