import Foundation

struct AnalyzerResult: Codable, Equatable {
    let summary: String
    let manipulationScore: Double
    let evidence: [String]
}

struct LocalHeuristicAnalyzer {
    func analyze(text: String) -> AnalyzerResult {
        let lowered = text.lowercased()
        let triggers = [
            "urgent",
            "limited time",
            "act now",
            "you must",
            "guaranteed",
            "secret",
            "they don't want you to know",
            "fear",
            "shocking"
        ]

        let hits = triggers.filter { lowered.contains($0) }
        let score = min(1.0, Double(hits.count) / 4.0)
        let summary: String

        if score >= 0.75 {
            summary = "High manipulation risk detected."
        } else if score >= 0.35 {
            summary = "Moderate manipulation risk detected."
        } else {
            summary = "Low manipulation risk detected."
        }

        return AnalyzerResult(
            summary: summary,
            manipulationScore: score,
            evidence: hits.isEmpty ? ["No high-pressure language matched."] : hits
        )
    }
}
