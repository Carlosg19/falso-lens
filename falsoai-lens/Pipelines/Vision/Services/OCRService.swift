import Foundation
import Vision
import AppKit
import OSLog

final class OCRService {
    nonisolated func recognizeText(in image: CGImage) throws -> [String] {
        let logger = Logger(
            subsystem: Bundle.main.bundleIdentifier ?? "com.falsoai.FalsoaiLens",
            category: "OCR"
        )
        logger.info("Starting Vision OCR width=\(image.width, privacy: .public), height=\(image.height, privacy: .public)")

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        logger.info("Configured VNRecognizeTextRequest recognitionLevel=accurate, usesLanguageCorrection=\(request.usesLanguageCorrection, privacy: .public), revision=\(request.revision, privacy: .public), recognitionLanguages=\(request.recognitionLanguages.joined(separator: ","), privacy: .public)")

        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do {
            try handler.perform([request])
        } catch {
            logger.error("Vision OCR failed: \(Self.errorLogDescription(for: error), privacy: .public)")
            throw error
        }

        let observations = request.results ?? []
        logger.info("Vision OCR completed observations=\(observations.count, privacy: .public)")

        let recognizedText = observations
            .compactMap { $0.topCandidates(1).first?.string }
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        logger.info("Vision OCR recognized non-empty lines=\(recognizedText.count, privacy: .public), totalCharacters=\(recognizedText.joined(separator: "\n").count, privacy: .public)")
        return recognizedText
    }

    nonisolated func recognizeJoinedText(in image: CGImage) throws -> String {
        let joinedText = try recognizeText(in: image)
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        Logger(
            subsystem: Bundle.main.bundleIdentifier ?? "com.falsoai.FalsoaiLens",
            category: "OCR"
        ).info("Vision OCR joined text characters=\(joinedText.count, privacy: .public)")
        return joinedText
    }

    private nonisolated static func errorLogDescription(for error: Error) -> String {
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
