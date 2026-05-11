import Combine
import Foundation
import OSLog
import SwiftUI

@MainActor
final class FileTranscriptionPipeline: ObservableObject {
    @Published private(set) var latestResult: TranscriptionResult?
    @Published private(set) var isTranscribing: Bool = false
    @Published private(set) var lastSelectedFileURL: URL?
    @Published private(set) var lastInferenceDurationSeconds: Double?
    @Published private(set) var errorMessage: String?

    private let engine: TranscriptionEngine?
    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.falsoai.FalsoaiLens",
        category: "FileTranscription"
    )

    init(engine: TranscriptionEngine? = nil) {
        if let engine {
            self.engine = engine
        } else {
            do {
                self.engine = try WhisperCppEngine()
            } catch let error as WhisperEngineError {
                self.engine = nil
                let message = error.errorDescription ?? "Whisper engine unavailable"
                let suggestion = error.recoverySuggestion ?? ""
                self.errorMessage = suggestion.isEmpty ? message : "\(message) \(suggestion)"
                logger.error("FileTranscriptionPipeline could not construct engine: \(message, privacy: .public). \(suggestion, privacy: .public)")
            } catch {
                self.engine = nil
                self.errorMessage = "Whisper engine unavailable: \(error.localizedDescription)"
                logger.error("FileTranscriptionPipeline failed to construct engine: \(String(describing: error), privacy: .public)")
            }
        }

        #if DEBUG
        WhisperOutputParser.runParserSmokeCheck()
        RMSVoiceActivityDetector.runVADSmokeCheck()
        TranscriptDuplicateAnalyzer.runDuplicateSmokeCheck()
        LiveAudioTranscriptionPipeline.runStateSmokeCheck()
        AudioTranscriptCache.runCacheSmokeCheck()
        #endif
    }

    var isEngineAvailable: Bool {
        engine != nil
    }

    func setSelectedFile(_ url: URL) {
        lastSelectedFileURL = url
        latestResult = nil
        lastInferenceDurationSeconds = nil
        errorMessage = nil
        logger.info("FileTranscription file selected path=\(url.path, privacy: .private)")
    }

    func transcribe(mode: TranscriptionMode) async {
        guard let engine else {
            errorMessage = errorMessage ?? "Whisper engine is not available."
            return
        }
        guard let userURL = lastSelectedFileURL else {
            errorMessage = "Pick a WAV file first."
            return
        }

        isTranscribing = true
        errorMessage = nil
        defer { isTranscribing = false }

        let didStartAccess = userURL.startAccessingSecurityScopedResource()
        defer {
            if didStartAccess {
                userURL.stopAccessingSecurityScopedResource()
            }
        }

        let workingURL: URL
        do {
            workingURL = try Self.copyToSandboxTemporary(userURL)
        } catch {
            errorMessage = "Could not stage audio file for transcription: \(error.localizedDescription)"
            logger.error("FileTranscription copy failed: \(String(describing: error), privacy: .public)")
            return
        }
        defer {
            try? FileManager.default.removeItem(at: workingURL)
        }

        let started = Date()
        do {
            let result = try await engine.transcribe(audioFile: workingURL, mode: mode)
            let elapsed = Date().timeIntervalSince(started)
            latestResult = result
            lastInferenceDurationSeconds = elapsed
            if result.text.isEmpty, result.segments.isEmpty {
                errorMessage = "No voice detected in the selected file. The file may be silent, or its content fell below the -40 dBFS detection threshold."
            }
            logger.info(
                "FileTranscription transcription completed mode=\(String(describing: mode), privacy: .public), elapsedSeconds=\(elapsed, privacy: .public), characters=\(result.text.count, privacy: .public), segments=\(result.segments.count, privacy: .public), language=\(result.language ?? "nil", privacy: .public)"
            )
        } catch let error as WhisperEngineError {
            let message = error.errorDescription ?? "Transcription failed."
            let suggestion = error.recoverySuggestion ?? ""
            errorMessage = suggestion.isEmpty ? message : "\(message) \(suggestion)"
            logger.error("FileTranscription transcription failed: \(message, privacy: .public)")
        } catch {
            errorMessage = "Transcription failed: \(error.localizedDescription)"
            logger.error("FileTranscription transcription failed (unexpected): \(String(describing: error), privacy: .public)")
        }
    }

    private static func copyToSandboxTemporary(_ source: URL) throws -> URL {
        let workingDirectory = URL(
            fileURLWithPath: NSTemporaryDirectory(),
            isDirectory: true
        ).appendingPathComponent("hearing-demo", isDirectory: true)
        try FileManager.default.createDirectory(
            at: workingDirectory,
            withIntermediateDirectories: true
        )

        let suffix = source.pathExtension.isEmpty ? "wav" : source.pathExtension
        let destination = workingDirectory
            .appendingPathComponent("input-\(UUID().uuidString)")
            .appendingPathExtension(suffix)
        try FileManager.default.copyItem(at: source, to: destination)
        return destination
    }
}
