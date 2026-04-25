import CoreGraphics
import CoreVideo
import Foundation
import OSLog
import ScreenCaptureKit

enum ScreenCaptureError: LocalizedError {
    case permissionDenied
    case noDisplayAvailable
    case screenshotUnavailable

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return "Screen recording permission is not granted for Falsoai Lens."
        case .noDisplayAvailable:
            return "No display was available for screen capture."
        case .screenshotUnavailable:
            return "ScreenCaptureKit completed without returning an image."
        }
    }

    var recoverySuggestion: String? {
        switch self {
        case .permissionDenied:
            return "Grant Screen Recording permission in System Settings, then quit and reopen the app before trying again."
        case .noDisplayAvailable:
            return "Connect or wake a display, then try capturing again."
        case .screenshotUnavailable:
            return "Try capturing again, or check Console logs for the ScreenCapture category."
        }
    }
}

@MainActor
final class ScreenCaptureService {
    private(set) var stream: SCStream?
    private(set) var isRunning = false
    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.falsoai.FalsoaiLens",
        category: "ScreenCapture"
    )

    func hasScreenRecordingPermission() -> Bool {
        let isAuthorized = CGPreflightScreenCaptureAccess()
        logger.info("ScreenCaptureService preflight returned \(isAuthorized, privacy: .public)")
        return isAuthorized
    }

    @discardableResult
    func requestScreenRecordingPermission() -> Bool {
        logger.info("ScreenCaptureService requesting screen recording permission")
        let isAuthorized = CGRequestScreenCaptureAccess()
        logger.info("ScreenCaptureService request returned \(isAuthorized, privacy: .public)")
        return isAuthorized
    }

    func prepareForCapture() throws {
        guard hasScreenRecordingPermission() else {
            logger.error("Screen recording preflight failed before capture")
            throw ScreenCaptureError.permissionDenied
        }
    }

    func captureMainDisplayImage() async throws -> CGImage {
        logger.info("Starting one-shot screen capture")
        logger.info("Capture runtime bundle=\(Bundle.main.bundleIdentifier ?? "unknown", privacy: .public), app=\(Bundle.main.bundlePath, privacy: .public), executable=\(Bundle.main.executablePath ?? "unknown", privacy: .public)")
        try prepareForCapture()
        logger.info("Screen recording preflight permission passed")

        let content: SCShareableContent
        do {
            logger.info("Loading SCShareableContent.current")
            content = try await SCShareableContent.current
        } catch {
            logger.error("SCShareableContent.current failed: \(Self.errorLogDescription(for: error), privacy: .public)")
            throw error
        }

        logger.info("Loaded shareable content. displays=\(content.displays.count, privacy: .public), windows=\(content.windows.count, privacy: .public), applications=\(content.applications.count, privacy: .public)")
        logger.info("Shareable display IDs: \(content.displays.map { String($0.displayID) }.joined(separator: ","), privacy: .public)")
        logger.info("Shareable applications sample: \(content.applications.prefix(8).map { "\($0.applicationName)(pid:\($0.processID))" }.joined(separator: ", "), privacy: .public)")

        guard let display = content.displays.first else {
            logger.error("No display available in shareable content")
            throw ScreenCaptureError.noDisplayAvailable
        }

        logger.info("Using display id=\(display.displayID, privacy: .public), width=\(display.width, privacy: .public), height=\(display.height, privacy: .public)")
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let configuration = SCStreamConfiguration()
        configuration.width = display.width
        configuration.height = display.height
        configuration.showsCursor = false
        configuration.queueDepth = 3
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        logger.info("Configured screenshot width=\(configuration.width, privacy: .public), height=\(configuration.height, privacy: .public), showsCursor=\(configuration.showsCursor, privacy: .public), queueDepth=\(configuration.queueDepth, privacy: .public), pixelFormat=\(configuration.pixelFormat, privacy: .public)")

        let captureLogger = logger
        return try await withCheckedThrowingContinuation { continuation in
            captureLogger.info("Calling SCScreenshotManager.captureImage")
            SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: configuration
            ) { image, error in
                if let error {
                    captureLogger.error("SCScreenshotManager capture failed: \(Self.errorLogDescription(for: error), privacy: .public)")
                    continuation.resume(throwing: error)
                    return
                }

                guard let image else {
                    captureLogger.error("SCScreenshotManager returned nil image without an error")
                    continuation.resume(throwing: ScreenCaptureError.screenshotUnavailable)
                    return
                }

                captureLogger.info("SCScreenshotManager returned image width=\(image.width, privacy: .public), height=\(image.height, privacy: .public)")
                continuation.resume(returning: image)
            }
        }
    }

    func stop() async {
        guard let stream else { return }
        try? await stream.stopCapture()
        self.stream = nil
        isRunning = false
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
