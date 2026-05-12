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
}
