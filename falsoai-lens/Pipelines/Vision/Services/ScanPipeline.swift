import Combine
import CoreGraphics
import Foundation
import OSLog

struct ScanResult: Identifiable, Equatable {
    let id: UUID
    let text: String
    let analyzerResult: AnalyzerResult
    let savedRecord: ScanRecord?
}

@MainActor
final class ScanPipeline: ObservableObject {
    @Published private(set) var latestResult: ScanResult?
    @Published private(set) var recentScans: [ScanRecord] = []
    @Published private(set) var isScanning = false
    @Published private(set) var lastOCRText = ""
    @Published private(set) var isCapturingScreen = false
    @Published private(set) var captureStatus = "Ready"
    @Published private(set) var errorMessage: String?

    private let analyzer = LocalHeuristicAnalyzer()
    private let notificationService: NotificationService
    private let ocrService = OCRService()
    private let screenCaptureService: ScreenCaptureService
    private let storage: ScanStorage?
    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.falsoai.FalsoaiLens",
        category: "ScanPipeline"
    )

    init(
        storage: ScanStorage? = nil,
        notificationService: NotificationService? = nil,
        screenCaptureService: ScreenCaptureService? = nil
    ) {
        self.storage = storage ?? (try? ScanStorage.makeDefault())
        self.notificationService = notificationService ?? NotificationService()
        self.screenCaptureService = screenCaptureService ?? ScreenCaptureService()
        refreshRecentScans()
    }

    func scan(text: String) async {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        logger.info("Starting analyzer scan inputCharacters=\(trimmedText.count, privacy: .public), source=manualOrOCR")
        guard !trimmedText.isEmpty else {
            logger.warning("Analyzer scan skipped because input is empty")
            errorMessage = "Enter text to scan."
            return
        }

        isScanning = true
        errorMessage = nil
        defer { isScanning = false }

        let result = analyzer.analyze(text: trimmedText)
        let record = ScanRecord(
            id: nil,
            capturedAt: Date(),
            sourceApplication: "Demo Input",
            recognizedText: trimmedText,
            analyzerSummary: result.summary,
            manipulationScore: result.manipulationScore,
            evidenceJSON: Self.evidenceJSON(from: result.evidence)
        )

        let savedRecord: ScanRecord?
        do {
            savedRecord = try storage?.save(record)
            logger.info("Saved scan record id=\(savedRecord?.id ?? -1, privacy: .public), score=\(result.manipulationScore, privacy: .public), evidenceCount=\(result.evidence.count, privacy: .public)")
            refreshRecentScans()
        } catch {
            savedRecord = nil
            logger.error("Failed to save scan record: \(Self.errorLogDescription(for: error), privacy: .public)")
            errorMessage = error.localizedDescription
        }

        latestResult = ScanResult(
            id: UUID(),
            text: trimmedText,
            analyzerResult: result,
            savedRecord: savedRecord
        )

        if result.manipulationScore >= 0.75 {
            logger.info("Sending manipulation notification score=\(result.manipulationScore, privacy: .public)")
            try? await notificationService.sendManipulationDetectedNotification(
                title: "Manipulation risk detected",
                body: result.summary
            )
        }
        logger.info("Analyzer scan finished score=\(result.manipulationScore, privacy: .public), summary=\(result.summary, privacy: .public)")
    }

    func captureScreenOCRAndScan() async {
        logger.info("Capture/OCR demo started")
        isCapturingScreen = true
        errorMessage = nil
        captureStatus = "Checking screen recording permission"
        defer { isCapturingScreen = false }

        do {
            logger.info("Requesting one-shot screen image from ScreenCaptureService")
            let image = try await screenCaptureService.captureMainDisplayImage()
            logger.info("Screen image captured width=\(image.width, privacy: .public), height=\(image.height, privacy: .public)")
            captureStatus = "Captured \(image.width) x \(image.height) image. Running OCR."

            logger.info("Running OCR for captured screen image")
            let recognizedText = try ocrService.recognizeJoinedText(in: image)
            lastOCRText = recognizedText
            logger.info("OCR finished characters=\(recognizedText.count, privacy: .public), isEmpty=\(recognizedText.isEmpty, privacy: .public)")
            logger.info("OCR content:\n\(recognizedText, privacy: .public)")

            guard !recognizedText.isEmpty else {
                logger.warning("Capture/OCR demo found no readable text")
                errorMessage = "No readable text found on the captured screen."
                captureStatus = "Capture succeeded, but OCR found no readable text."
                return
            }

            captureStatus = "OCR found \(recognizedText.count) characters. Running analyzer."
            await scan(text: recognizedText)
            captureStatus = "Screen capture, OCR, and analysis completed."
            logger.info("Capture/OCR demo completed")
        } catch {
            let message = Self.message(for: error)
            logger.error("Capture/OCR demo failed: \(Self.errorLogDescription(for: error), privacy: .public)")
            errorMessage = message
            captureStatus = "Capture failed: \(message)"
        }
    }

    func refreshRecentScans() {
        recentScans = (try? storage?.fetchRecent(limit: 20)) ?? []
        logger.info("Refreshed recent scans count=\(self.recentScans.count, privacy: .public)")
    }

    private static func evidenceJSON(from evidence: [String]) -> String? {
        guard let data = try? JSONEncoder().encode(evidence) else {
            return nil
        }

        return String(data: data, encoding: .utf8)
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
