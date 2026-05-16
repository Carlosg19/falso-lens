import Foundation

struct StubScreenTextWindowAnalyzer: ScreenTextWindowAnalyzing {
    let analyzerID = "stub-summary-1"

    init() {}

    func analyze(_ document: ScreenTextWindowSegmentDocument) async throws -> ScreenTextWindowAnalysis {
        let started = Date()
        let payloadJSON = (try? compactJSON(document)) ?? ""
        let summary = makeSummary(document: document, payloadJSON: payloadJSON)
        let elapsed = Date().timeIntervalSince(started)
        let window = document.window

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

    private func compactJSON(_ document: ScreenTextWindowSegmentDocument) throws -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(document)
        return String(decoding: data, as: UTF8.self)
    }

    private func makeSummary(
        document: ScreenTextWindowSegmentDocument,
        payloadJSON: String
    ) -> String {
        let window = document.window
        let header = """
        ## Stub Window Summary

        - Sequence: \(window.sequenceNumber)
        - Window: \(window.startedAt.formatted()) -> \(window.endedAt.formatted())
        - Duration: \(Int(window.durationSeconds.rounded())) s
        - Unique lines: \(window.encounterCount)
        - Segments: \(document.segments.count)
        """

        let segmentSummary: String
        if document.segments.isEmpty {
            segmentSummary = "_(none)_"
        } else {
            segmentSummary = document.segments
                .map { segment in
                    "- d\(segment.displayIndex + 1) role=\(segment.role.rawValue) lines=\(segment.lineCount) sightings=\(segment.totalSightingCount) repeatedUI=\(segment.isRepeatedUI)"
                }
                .joined(separator: "\n")
        }

        let preview: String
        if document.segments.isEmpty {
            preview = "_(none)_"
        } else {
            preview = document.segments
                .sorted { $0.firstSightedAt < $1.firstSightedAt }
                .prefix(10)
                .map { segment in
                    "- [role \(segment.role.rawValue), lines \(segment.lineCount)] \(segment.text)"
                }
                .joined(separator: "\n")
        }

        return """
        \(header)

        ### Segments
        \(segmentSummary)

        ### Top segment text (chronological, first 10)
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

    private static func sampleDocument(segments: [ScreenTextWindowSegmentDTO] = []) -> ScreenTextWindowSegmentDocument {
        ScreenTextWindowSegmentDocument(
            window: ScreenTextWindowMetadataDTO(
                id: UUID(),
                sessionID: UUID(),
                sequenceNumber: 7,
                startedAt: Date(timeIntervalSince1970: 0),
                endedAt: Date(timeIntervalSince1970: 300),
                durationSeconds: 300,
                displayCount: segments.isEmpty ? 0 : 1,
                encounterCount: segments.reduce(0) { $0 + $1.lineCount },
                segmentCount: segments.count
            ),
            segments: segments
        )
    }

    private static func sampleSegment(text: String, role: ScreenTextStructureRole = .unknown) -> ScreenTextWindowSegmentDTO {
        ScreenTextWindowSegmentDTO(
            id: "display-0-\(role.rawValue)-\(text)",
            displayID: 1,
            displayIndex: 0,
            role: role,
            bounds: ScreenTextWindowBoundsDTO(x: 0, y: 0, width: 100, height: 20),
            text: text,
            lineCount: 1,
            totalSightingCount: 3,
            firstSightedAt: Date(timeIntervalSince1970: 10),
            lastSightedAt: Date(timeIntervalSince1970: 20),
            isRepeatedUI: false
        )
    }

    private static func verifyAnalyzerProducesAnalysisCarryingWindowIdentity() async {
        let analyzer = StubScreenTextWindowAnalyzer()
        let document = sampleDocument(segments: [sampleSegment(text: "hello")])
        let analysis = try? await analyzer.analyze(document)
        let window = document.window
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
        let document = sampleDocument(segments: [
            sampleSegment(text: "alpha"),
            sampleSegment(text: "beta")
        ])
        let analysis = try? await analyzer.analyze(document)
        let summary = analysis?.summaryMarkdown ?? ""
        assert(summary.contains("Unique lines: 2"),
               "Stub summary missing encounter count line")
        assert(summary.contains("alpha") && summary.contains("beta"),
               "Stub summary missing segment texts")
    }

    private static func verifyEmptyWindowStillProducesAnalysis() async {
        let analyzer = StubScreenTextWindowAnalyzer()
        let document = sampleDocument()
        let analysis = try? await analyzer.analyze(document)
        assert(analysis != nil, "Stub analyzer threw on empty document")
        assert(analysis?.encounterCount == 0, "Stub analysis encounterCount mismatch on empty document")
        assert(analysis?.summaryMarkdown.contains("_(none)_") == true,
               "Stub summary did not mark empty segments")
    }
}
#endif
