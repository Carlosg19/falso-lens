import Combine
import CoreGraphics
import Foundation
import OSLog

@MainActor
final class ScreenTextPipeline: ObservableObject {
    @Published private(set) var latestCapture: ScreenTextRecord?
    @Published private(set) var latestDocument: MultiDisplayScreenTextDocument?
    @Published private(set) var recentCaptures: [ScreenTextRecord] = []
    @Published private(set) var lastOCRText = ""
    @Published private(set) var lastCaptureUsedCache = false
    @Published private(set) var lastCapturedDisplayCount = 0
    @Published private(set) var isCapturingScreen = false
    @Published private(set) var captureStatus = "Ready"
    @Published private(set) var errorMessage: String?

    private let ocrService = OCRService()
    private let screenCaptureService: ScreenCaptureService
    private let documentBuilder = ScreenTextDocumentBuilder()
    private var displayMemories: [UInt32: ScreenTextMemory] = [:]
    private let storage: ScreenTextStorage?
    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.falsoai.FalsoaiLens",
        category: "ScreenTextPipeline"
    )

    init(
        storage: ScreenTextStorage? = nil,
        screenCaptureService: ScreenCaptureService? = nil
    ) {
        self.storage = storage ?? (try? ScreenTextStorage.makeDefault())
        self.screenCaptureService = screenCaptureService ?? ScreenCaptureService()
        refreshRecentCaptures()
    }

    func captureScreenText() async {
        logger.info("Screen text capture started")
        isCapturingScreen = true
        errorMessage = nil
        captureStatus = "Checking screen recording permission"
        defer { isCapturingScreen = false }

        do {
            let frames = try await screenCaptureService.captureAllDisplayImages()
            let capturedAt = Date()
            lastCapturedDisplayCount = frames.count
            captureStatus = "Captured \(frames.count) display\(frames.count == 1 ? "" : "s"). Checking cache."

            var displayDocuments: [DisplayScreenTextDocument] = []
            var reusedCacheCount = 0

            for frame in frames {
                let frameHash = ScreenTextHasher.displayFrameHash(
                    displayID: frame.displayID,
                    image: frame.image
                )
                let memory = memory(forDisplayID: frame.displayID)

                if let cachedDocument = await memory.cachedDocument(forFrameHash: frameHash) {
                    reusedCacheCount += 1
                    displayDocuments.append(
                        DisplayScreenTextDocument(
                            displayID: frame.displayID,
                            index: frame.index,
                            document: cachedDocument
                        )
                    )
                    logger.info("Screen text capture reused cached document id=\(cachedDocument.id.uuidString, privacy: .public), displayID=\(frame.displayID, privacy: .public)")
                    continue
                }

                captureStatus = "Running OCR for display \(frame.index + 1) of \(frames.count)."
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

            let aggregateDocument = MultiDisplayScreenTextDocument(
                capturedAt: capturedAt,
                displays: displayDocuments.sorted { $0.index < $1.index }
            )
            latestDocument = aggregateDocument
            lastCaptureUsedCache = reusedCacheCount == frames.count

            let recognizedText = aggregateDocument.recognizedText.trimmingCharacters(in: .whitespacesAndNewlines)
            lastOCRText = recognizedText

            guard !recognizedText.isEmpty else {
                logger.warning("Screen text capture found no readable text")
                errorMessage = "No readable text found on the captured screen."
                captureStatus = "Capture succeeded, but OCR found no readable text."
                return
            }

            if reusedCacheCount == frames.count {
                captureStatus = "Screen text loaded from memory cache for \(frames.count) display\(frames.count == 1 ? "" : "s")."
            } else {
                let source = frames.count == 1 ? "Display 1" : "All Displays"
                let savedRecord = try saveText(recognizedText, source: source)
                latestCapture = savedRecord
                captureStatus = "Screen text captured from \(frames.count) display\(frames.count == 1 ? "" : "s"), structured, cached, and saved."
            }

            logger.info("Screen text capture completed displays=\(aggregateDocument.displays.count, privacy: .public), characters=\(recognizedText.count, privacy: .public), observations=\(aggregateDocument.observationCount, privacy: .public), lines=\(aggregateDocument.lineCount, privacy: .public), blocks=\(aggregateDocument.blockCount, privacy: .public), regions=\(aggregateDocument.regionCount, privacy: .public), cachedDisplays=\(reusedCacheCount, privacy: .public)")
        } catch {
            let message = Self.message(for: error)
            logger.error("Screen text capture failed: \(Self.errorLogDescription(for: error), privacy: .public)")
            errorMessage = message
            captureStatus = "Capture failed: \(message)"
        }
    }

    private func memory(forDisplayID displayID: UInt32) -> ScreenTextMemory {
        if let memory = displayMemories[displayID] {
            return memory
        }

        let memory = ScreenTextMemory()
        displayMemories[displayID] = memory
        return memory
    }

    @discardableResult
    func saveText(_ text: String, source: String) throws -> ScreenTextRecord {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else {
            throw ScreenTextPipelineError.emptyText
        }

        let record = ScreenTextRecord(
            id: nil,
            capturedAt: Date(),
            source: source,
            recognizedText: trimmedText,
            characterCount: trimmedText.count
        )

        let savedRecord = try storage?.save(record) ?? record
        refreshRecentCaptures()
        return savedRecord
    }

    func refreshRecentCaptures() {
        recentCaptures = (try? storage?.fetchRecent(limit: 20)) ?? []
        logger.info("Refreshed recent screen text captures count=\(self.recentCaptures.count, privacy: .public)")
    }

    private static func message(for error: Error) -> String {
        let nsError = error as NSError

        if let recoverySuggestion = nsError.localizedRecoverySuggestion,
           !recoverySuggestion.isEmpty {
            return "\(nsError.localizedDescription) \(recoverySuggestion)"
        }

        return nsError.localizedDescription
    }

    private static func errorLogDescription(for error: Error) -> String {
        let nsError = error as NSError
        let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError
        let underlyingDescription = underlying.map {
            "underlyingDomain=\($0.domain), underlyingCode=\($0.code), underlyingDescription=\($0.localizedDescription)"
        } ?? "underlying=nil"
        let userInfoKeys = nsError.userInfo.keys
            .map { "\($0)" }
            .sorted()
            .joined(separator: ",")

        return [
            "type=\(type(of: error))",
            "domain=\(nsError.domain)",
            "code=\(nsError.code)",
            "description=\(nsError.localizedDescription)",
            "failureReason=\(nsError.localizedFailureReason ?? "nil")",
            "recoverySuggestion=\(nsError.localizedRecoverySuggestion ?? "nil")",
            underlyingDescription,
            "userInfoKeys=\(userInfoKeys.isEmpty ? "none" : userInfoKeys)"
        ].joined(separator: " | ")
    }
}

enum ScreenTextPipelineError: LocalizedError {
    case emptyText

    var errorDescription: String? {
        switch self {
        case .emptyText:
            return "No text was available to save."
        }
    }
}
