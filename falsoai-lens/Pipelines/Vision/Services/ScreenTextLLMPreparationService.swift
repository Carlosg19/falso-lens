import CoreGraphics
import Foundation

struct ScreenTextLLMPreparation: Equatable, Sendable {
    let factualDocument: ScreenTextLLMDocument
    let structuredDocument: ScreenTextStructuredLLMDocument
    let factualMarkdown: String
    let compactJSON: String
    let chunks: [ScreenTextLLMChunk]
    let structuredMarkdown: String
}

struct ScreenTextLLMPreparationService {
    private let exporter: ScreenTextLLMExporter
    private let classifier: any ScreenTextStructureClassifying
    private let promptExporter: ScreenTextStructuredPromptExporter

    init(
        exporter: ScreenTextLLMExporter = ScreenTextLLMExporter(),
        classifier: any ScreenTextStructureClassifying = HeuristicScreenTextStructureClassifier(),
        promptExporter: ScreenTextStructuredPromptExporter = ScreenTextStructuredPromptExporter()
    ) {
        self.exporter = exporter
        self.classifier = classifier
        self.promptExporter = promptExporter
    }

    func prepare(
        _ document: MultiDisplayScreenTextDocument,
        maxChunkCharacters: Int = 6_000
    ) throws -> ScreenTextLLMPreparation {
        let factualDocument = exporter.export(document)
        let structuredDocument = classifier.classify(factualDocument)

        return ScreenTextLLMPreparation(
            factualDocument: factualDocument,
            structuredDocument: structuredDocument,
            factualMarkdown: exporter.anchoredMarkdown(from: factualDocument),
            compactJSON: try exporter.compactJSON(from: factualDocument),
            chunks: exporter.chunks(from: factualDocument, maxCharacters: maxChunkCharacters),
            structuredMarkdown: promptExporter.markdown(from: structuredDocument)
        )
    }

    func prepare(
        _ snapshot: RealtimeScreenTextSnapshot,
        maxChunkCharacters: Int = 6_000
    ) throws -> ScreenTextLLMPreparation {
        try prepare(snapshot.document, maxChunkCharacters: maxChunkCharacters)
    }

    func prepare(_ window: ScreenTextWindow) -> String {
        var output: [String] = []
        output.append("# Screen Text Window")
        output.append("")
        output.append("- sessionID: \(window.sessionID.uuidString)")
        output.append("- sequence: \(window.sequenceNumber)")
        output.append("- startedAt: \(window.startedAt.ISO8601Format())")
        output.append("- endedAt: \(window.endedAt.ISO8601Format())")
        output.append("- durationSeconds: \(Int(window.durationSeconds.rounded()))")
        output.append("- encounterCount: \(window.encounterCount)")
        output.append("")
        output.append("## Encounters (chronological)")
        output.append("")

        if window.encounters.isEmpty {
            output.append("_No readable text was captured during this window._")
            return output.joined(separator: "\n")
        }

        let sortedEncounters = window.encounters.sorted { lhs, rhs in
            if lhs.firstSeenAt != rhs.firstSeenAt {
                return lhs.firstSeenAt < rhs.firstSeenAt
            }
            return lhs.text.localizedStandardCompare(rhs.text) == .orderedAscending
        }

        for encounter in sortedEncounters {
            let firstSeen = encounter.firstSeenAt.formatted(date: .omitted, time: .standard)
            let lastSeen = encounter.lastSeenAt.formatted(date: .omitted, time: .standard)
            let line = "- [\(firstSeen) → \(lastSeen) ×\(encounter.seenCount), display \(encounter.latestSource.displayIndex)] \(encounter.text)"
            output.append(line)
        }

        return output.joined(separator: "\n")
    }
}

#if DEBUG
extension ScreenTextLLMPreparationService {
    static func runSmokeChecks() {
        verifyEmptyWindowProducesEmptyEncountersSection()
        verifyWindowFormatsEncountersChronologically()
    }

    private static func verifyEmptyWindowProducesEmptyEncountersSection() {
        let service = ScreenTextLLMPreparationService()
        let window = ScreenTextWindow(
            id: UUID(),
            sessionID: UUID(),
            sequenceNumber: 1,
            startedAt: Date(timeIntervalSince1970: 0),
            endedAt: Date(timeIntervalSince1970: 300),
            encounters: []
        )
        let prompt = service.prepare(window)
        assert(prompt.contains("encounterCount: 0"),
               "Empty window prompt missing encounterCount: 0")
        assert(prompt.contains("_No readable text was captured during this window._"),
               "Empty window prompt missing empty-marker")
    }

    private static func verifyWindowFormatsEncountersChronologically() {
        let service = ScreenTextLLMPreparationService()
        let earlier = Date(timeIntervalSince1970: 100)
        let later = Date(timeIntervalSince1970: 200)
        let window = ScreenTextWindow(
            id: UUID(),
            sessionID: UUID(),
            sequenceNumber: 2,
            startedAt: Date(timeIntervalSince1970: 0),
            endedAt: Date(timeIntervalSince1970: 300),
            encounters: [
                ScreenTextEncounter(
                    text: "later line",
                    normalizedTextHash: "h-later",
                    firstSeenAt: later,
                    lastSeenAt: later,
                    seenCount: 1,
                    latestSource: ScreenTextEncounterSource(displayID: 1, displayIndex: 0, bounds: .zero)
                ),
                ScreenTextEncounter(
                    text: "earlier line",
                    normalizedTextHash: "h-earlier",
                    firstSeenAt: earlier,
                    lastSeenAt: earlier,
                    seenCount: 1,
                    latestSource: ScreenTextEncounterSource(displayID: 1, displayIndex: 0, bounds: .zero)
                )
            ]
        )
        let prompt = service.prepare(window)
        guard let earlierIndex = prompt.range(of: "earlier line"),
              let laterIndex = prompt.range(of: "later line") else {
            assertionFailure("Prompt missing one of the encounter texts")
            return
        }
        assert(earlierIndex.lowerBound < laterIndex.lowerBound,
               "Encounters not sorted chronologically in prompt")
    }
}
#endif
