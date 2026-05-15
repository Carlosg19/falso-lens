import CoreGraphics
import Foundation

struct StubScreenTextWindowAnalyzer: ScreenTextWindowAnalyzing {
    let analyzerID = "stub-summary-1"
    private let promptBuilder: ScreenTextLLMPreparationService
    private let segmentReducer: ScreenTextWindowSegmentReducer

    init(
        promptBuilder: ScreenTextLLMPreparationService = ScreenTextLLMPreparationService(),
        segmentReducer: ScreenTextWindowSegmentReducer = ScreenTextWindowSegmentReducer()
    ) {
        self.promptBuilder = promptBuilder
        self.segmentReducer = segmentReducer
    }

    func analyze(_ window: ScreenTextWindow) async throws -> ScreenTextWindowAnalysis {
        let started = Date()
        let segments = segmentReducer.reduce(window)
        let payloadJSON = (try? promptBuilder.prepareSegmentDocumentJSON(window)) ?? ""
        let summary = makeSummary(window: window, payloadJSON: payloadJSON, segments: segments)
        let elapsed = Date().timeIntervalSince(started)

        return ScreenTextWindowAnalysis(
            id: UUID(),
            windowID: window.id,
            sessionID: window.sessionID,
            sequenceNumber: window.sequenceNumber,
            windowStartedAt: window.startedAt,
            windowEndedAt: window.endedAt,
            generatedAt: Date(),
            analyzerID: analyzerID,
            summaryMarkdown: summary,
            encounterCount: window.encounterCount,
            latencySeconds: elapsed,
            errorMessage: nil
        )
    }

    private func makeSummary(
        window: ScreenTextWindow,
        payloadJSON: String,
        segments: [ScreenTextWindowSegment]
    ) -> String {
        let header = """
        ## Stub Window Summary

        - Sequence: \(window.sequenceNumber)
        - Window: \(window.startedAt.formatted()) → \(window.endedAt.formatted())
        - Duration: \(Int(window.durationSeconds.rounded())) s
        - Unique lines: \(window.encounterCount)
        - Segments: \(segments.count)
        """

        let preview: String
        if window.encounters.isEmpty {
            preview = "_(none)_"
        } else {
            preview = window.encounters
                .sorted { $0.firstSeenAt < $1.firstSeenAt }
                .prefix(10)
                .map { encounter in
                    "- [seen \(encounter.seenCount)x, role \(encounter.dominantRole.rawValue)] \(encounter.text)"
                }
                .joined(separator: "\n")
        }

        let segmentSummary: String
        if segments.isEmpty {
            segmentSummary = "_(none)_"
        } else {
            segmentSummary = segments
                .map { segment in
                    "- d\(segment.displayIndex + 1) role=\(segment.role.rawValue) lines=\(segment.lineCount) sightings=\(segment.totalSightingCount) repeatedUI=\(segment.isRepeatedUI)"
                }
                .joined(separator: "\n")
        }

        return """
        \(header)

        ### Segments
        \(segmentSummary)

        ### Top encounters (chronological, first 10)
        \(preview)

        ---
        LLM payload size: \(payloadJSON.utf8.count) bytes (segment document; would be sent to a real LLM here)
        """
    }
}

#if DEBUG
extension StubScreenTextWindowAnalyzer {
    static func runSmokeChecks() async {
        await verifyAnalyzerProducesAnalysisCarryingWindowIdentity()
        await verifyAnalyzerSummaryMentionsEncounterCount()
        await verifyEmptyWindowStillProducesAnalysis()
    }

    private static func sampleWindow(encounters: [ScreenTextEncounter] = []) -> ScreenTextWindow {
        ScreenTextWindow(
            id: UUID(),
            sessionID: UUID(),
            sequenceNumber: 7,
            startedAt: Date(timeIntervalSince1970: 0),
            endedAt: Date(timeIntervalSince1970: 300),
            encounters: encounters
        )
    }

    private static func sampleEncounter(text: String) -> ScreenTextEncounter {
        let firstSeen = Date(timeIntervalSince1970: 10)
        let lastSeen = Date(timeIntervalSince1970: 20)
        return ScreenTextEncounter(
            text: text,
            normalizedTextHash: "hash-\(text)",
            displayID: 1,
            displayIndex: 0,
            firstSeenAt: firstSeen,
            lastSeenAt: lastSeen,
            seenCount: 3,
            sightings: [ScreenTextEncounterSighting(bounds: .zero, sightedAt: lastSeen, role: .unknown, blockAlias: nil)],
            roleCounts: [.unknown: 3]
        )
    }

    private static func verifyAnalyzerProducesAnalysisCarryingWindowIdentity() async {
        let analyzer = StubScreenTextWindowAnalyzer()
        let window = sampleWindow(encounters: [sampleEncounter(text: "hello")])
        let analysis = try? await analyzer.analyze(window)
        assert(analysis != nil, "Stub analyzer threw")
        assert(analysis?.windowID == window.id, "Analysis windowID does not match window")
        assert(analysis?.sessionID == window.sessionID, "Analysis sessionID does not match window")
        assert(analysis?.sequenceNumber == window.sequenceNumber, "Analysis sequenceNumber mismatch")
        assert(analysis?.analyzerID == "stub-summary-1", "Analysis analyzerID is not the stub id")
        assert(analysis?.windowStartedAt == window.startedAt, "Analysis windowStartedAt mismatch")
        assert(analysis?.windowEndedAt == window.endedAt, "Analysis windowEndedAt mismatch")
        assert(analysis?.errorMessage == nil, "Stub analyzer set an error message on success")
    }

    private static func verifyAnalyzerSummaryMentionsEncounterCount() async {
        let analyzer = StubScreenTextWindowAnalyzer()
        let window = sampleWindow(encounters: [
            sampleEncounter(text: "alpha"),
            sampleEncounter(text: "beta")
        ])
        let analysis = try? await analyzer.analyze(window)
        let summary = analysis?.summaryMarkdown ?? ""
        assert(summary.contains("Unique lines: 2"),
               "Stub summary missing encounter count line")
        assert(summary.contains("alpha") && summary.contains("beta"),
               "Stub summary missing encounter texts")
    }

    private static func verifyEmptyWindowStillProducesAnalysis() async {
        let analyzer = StubScreenTextWindowAnalyzer()
        let window = sampleWindow()
        let analysis = try? await analyzer.analyze(window)
        assert(analysis != nil, "Stub analyzer threw on empty window")
        assert(analysis?.encounterCount == 0, "Stub analysis encounterCount mismatch on empty window")
        assert(analysis?.summaryMarkdown.contains("_(none)_") == true,
               "Stub summary did not mark empty encounters")
    }
}
#endif
