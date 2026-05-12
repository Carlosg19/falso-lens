import CoreGraphics
import Foundation
import OSLog

@MainActor
final class RealtimeScreenTextSampler {
    private let screenCaptureService: ScreenCaptureService
    private let ocrService: OCRService
    private let documentBuilder: ScreenTextDocumentBuilder
    private let exporter: ScreenTextLLMExporter
    private var displayMemories: [UInt32: ScreenTextMemory] = [:]
    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.falsoai.FalsoaiLens",
        category: "RealtimeScreenTextSampler"
    )

    init(
        screenCaptureService: ScreenCaptureService? = nil,
        ocrService: OCRService? = nil,
        documentBuilder: ScreenTextDocumentBuilder? = nil,
        exporter: ScreenTextLLMExporter? = nil
    ) {
        self.screenCaptureService = screenCaptureService ?? ScreenCaptureService()
        self.ocrService = ocrService ?? OCRService()
        self.documentBuilder = documentBuilder ?? ScreenTextDocumentBuilder()
        self.exporter = exporter ?? ScreenTextLLMExporter()
    }

    func sample(sessionID: UUID, sequenceNumber: Int) async throws -> RealtimeScreenTextSnapshot {
        try await sampleAllDisplays(
            sessionID: sessionID,
            sequenceNumber: sequenceNumber
        )
    }

    private func sampleAllDisplays(
        sessionID: UUID,
        sequenceNumber: Int
    ) async throws -> RealtimeScreenTextSnapshot {
        let started = Date()
        let frames = try await screenCaptureService.captureAllDisplayImages()
        let capturedAt = Date()

        var displayDocuments: [DisplayScreenTextDocument] = []
        var displayFrameHashes: [String] = []
        var reusedDisplayCount = 0
        var ocrDisplayCount = 0

        for frame in frames {
            let frameHash = ScreenTextHasher.displayFrameHash(
                displayID: frame.displayID,
                image: frame.image
            )
            displayFrameHashes.append(frameHash)

            let memory = memory(forDisplayID: frame.displayID)
            if let cachedDocument = await memory.cachedDocument(forFrameHash: frameHash) {
                reusedDisplayCount += 1
                displayDocuments.append(
                    DisplayScreenTextDocument(
                        displayID: frame.displayID,
                        index: frame.index,
                        document: cachedDocument
                    )
                )
                continue
            }

            ocrDisplayCount += 1
            let observations = try ocrService.recognizeTextObservations(in: frame.image)
            let document = documentBuilder.build(
                observations: observations,
                frameSize: CGSize(width: CGFloat(frame.image.width), height: CGFloat(frame.image.height)),
                frameHash: frameHash,
                capturedAt: capturedAt
            )
            let storedDocument = await memory.store(document)
            displayDocuments.append(
                DisplayScreenTextDocument(
                    displayID: frame.displayID,
                    index: frame.index,
                    document: storedDocument
                )
            )
        }

        let document = MultiDisplayScreenTextDocument(
            capturedAt: capturedAt,
            displays: displayDocuments.sorted { $0.index < $1.index }
        )
        let recognizedText = document.recognizedText.trimmingCharacters(in: .whitespacesAndNewlines)

        logger.info(
            "Realtime screen text sample sequence=\(sequenceNumber, privacy: .public), displays=\(document.displays.count, privacy: .public), characters=\(recognizedText.count, privacy: .public), reusedDisplays=\(reusedDisplayCount, privacy: .public), ocrDisplays=\(ocrDisplayCount, privacy: .public)"
        )

        return try makeSnapshot(
            sessionID: sessionID,
            sequenceNumber: sequenceNumber,
            capturedAt: capturedAt,
            document: document,
            displayFrameHashes: displayFrameHashes,
            reusedDisplayCount: reusedDisplayCount,
            ocrDisplayCount: ocrDisplayCount,
            elapsedSeconds: Date().timeIntervalSince(started)
        )
    }

    private func makeSnapshot(
        sessionID: UUID,
        sequenceNumber: Int,
        capturedAt: Date,
        document: MultiDisplayScreenTextDocument,
        displayFrameHashes: [String],
        reusedDisplayCount: Int,
        ocrDisplayCount: Int,
        elapsedSeconds: Double
    ) throws -> RealtimeScreenTextSnapshot {
        let exportedDocument = exporter.export(document)
        let markdown = exporter.anchoredMarkdown(from: exportedDocument)
        let compactJSON = try exporter.compactJSON(from: exportedDocument)
        let chunks = exporter.chunks(from: exportedDocument)
        let recognizedText = document.recognizedText.trimmingCharacters(in: .whitespacesAndNewlines)

        return RealtimeScreenTextSnapshot(
            sessionID: sessionID,
            sequenceNumber: sequenceNumber,
            capturedAt: capturedAt,
            document: document,
            recognizedText: recognizedText,
            markdownExport: markdown,
            compactJSONExport: compactJSON,
            chunkCount: chunks.count,
            displayCount: document.displays.count,
            observationCount: document.observationCount,
            lineCount: document.lineCount,
            blockCount: document.blockCount,
            regionCount: document.regionCount,
            aggregateTextHash: ScreenTextHasher.hashAggregateText(document),
            aggregateLayoutHash: ScreenTextHasher.hashAggregateLayout(document),
            displayFrameHashes: displayFrameHashes,
            reusedDisplayCount: reusedDisplayCount,
            ocrDisplayCount: ocrDisplayCount,
            elapsedSeconds: elapsedSeconds
        )
    }

    private func memory(forDisplayID displayID: UInt32) -> ScreenTextMemory {
        if let memory = displayMemories[displayID] {
            return memory
        }

        let memory = ScreenTextMemory()
        displayMemories[displayID] = memory
        return memory
    }
}
