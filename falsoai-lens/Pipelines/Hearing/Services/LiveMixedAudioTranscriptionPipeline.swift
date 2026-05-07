import Combine
import Foundation
import OSLog
import SwiftUI

@MainActor
final class LiveMixedAudioTranscriptionPipeline: ObservableObject {
    @Published private(set) var transcriptText = ""
    @Published private(set) var isRunning = false
    @Published private(set) var isProcessingChunk = false
    @Published private(set) var statusText = "Computer + mic transcription is stopped."
    @Published private(set) var errorMessage: String?
    @Published private(set) var lastInferenceDurationSeconds: Double?
    @Published private(set) var chunksTranscribed = 0
    @Published private(set) var latestLanguage: String?

    private let captureService: ComputerMicrophoneAudioCaptureService
    private let mixer: MixedAudioBufferStore?
    private let normalizer: AudioNormalizer?
    private let engine: TranscriptionEngine?
    private let logger: Logger
    private var captureTask: Task<Void, Never>?

    init(
        captureService: ComputerMicrophoneAudioCaptureService? = nil,
        mixer: MixedAudioBufferStore? = nil,
        normalizer: AudioNormalizer? = nil,
        engine: TranscriptionEngine? = nil,
        logger: Logger = Logger(
            subsystem: Bundle.main.bundleIdentifier ?? "com.falsoai.FalsoaiLens",
            category: "LiveMixedTranscription"
        )
    ) {
        self.captureService = captureService ?? ComputerMicrophoneAudioCaptureService()
        self.logger = logger

        if let mixer {
            self.mixer = mixer
        } else {
            self.mixer = try? MixedAudioBufferStore()
        }

        if let normalizer {
            self.normalizer = normalizer
        } else {
            self.normalizer = try? AudioNormalizer()
        }

        if let engine {
            self.engine = engine
        } else {
            do {
                self.engine = try WhisperCppEngine()
            } catch let error as WhisperEngineError {
                self.engine = nil
                let message = error.errorDescription ?? "Whisper engine unavailable."
                let suggestion = error.recoverySuggestion ?? ""
                self.errorMessage = suggestion.isEmpty ? message : "\(message) \(suggestion)"
                logger.error("Live mixed pipeline could not construct engine: \(message, privacy: .public). \(suggestion, privacy: .public)")
            } catch {
                self.engine = nil
                self.errorMessage = "Whisper engine unavailable: \(error.localizedDescription)"
                logger.error("Live mixed pipeline failed to construct engine: \(String(describing: error), privacy: .public)")
            }
        }

        if self.mixer == nil {
            errorMessage = "Mixed audio buffer could not be initialized."
        }
        if self.normalizer == nil {
            errorMessage = "Audio normalizer could not be initialized."
        }
    }

    var isEngineAvailable: Bool {
        engine != nil && mixer != nil && normalizer != nil
    }

    func start(mode: TranscriptionMode) async {
        guard !isRunning else { return }
        guard let mixer, let normalizer, let engine else {
            errorMessage = errorMessage ?? "Live transcription is not available."
            return
        }

        await mixer.clear()
        transcriptText = ""
        errorMessage = nil
        lastInferenceDurationSeconds = nil
        chunksTranscribed = 0
        latestLanguage = nil
        isProcessingChunk = false
        statusText = "Starting computer + mic capture..."

        let stream: AsyncStream<CapturedAudioPacket>
        do {
            stream = try await captureService.startCapture()
        } catch {
            errorMessage = Self.userFacingMessage(for: error)
            statusText = "Computer + mic transcription could not start."
            logger.error("Live mixed capture failed to start: \(String(describing: error), privacy: .public)")
            return
        }

        isRunning = true
        statusText = "Listening to computer audio and microphone..."

        captureTask = Task.detached(priority: .userInitiated) { [weak self, mixer, normalizer, engine, stream, mode] in
            for await packet in stream {
                if Task.isCancelled { break }

                do {
                    let chunks = try await mixer.append(packet)
                    for chunk in chunks {
                        if Task.isCancelled { break }
                        await self?.transcribe(chunk: chunk, normalizer: normalizer, engine: engine, mode: mode)
                    }
                } catch {
                    await self?.handleLiveError(error)
                }
            }

            await self?.handleCaptureStreamEnded()
        }

        logger.info("Live mixed transcription started mode=\(String(describing: mode), privacy: .public)")
    }

    func stop() async {
        captureTask?.cancel()
        captureTask = nil
        await captureService.stopCapture()
        await mixer?.clear()

        isRunning = false
        isProcessingChunk = false
        statusText = chunksTranscribed > 0
            ? "Stopped after \(chunksTranscribed) transcript chunks."
            : "Computer + mic transcription is stopped."

        logger.info("Live mixed transcription stopped chunks=\(self.chunksTranscribed, privacy: .public)")
    }

    func clearTranscript() {
        transcriptText = ""
        chunksTranscribed = 0
        latestLanguage = nil
        lastInferenceDurationSeconds = nil
        errorMessage = nil
        statusText = isRunning
            ? "Listening to computer audio and microphone..."
            : "Computer + mic transcription is stopped."
    }

    private func transcribe(
        chunk: BufferedAudioChunk,
        normalizer: AudioNormalizer,
        engine: TranscriptionEngine,
        mode: TranscriptionMode
    ) async {
        isProcessingChunk = true
        statusText = "Transcribing recent audio..."
        let started = Date()

        do {
            let normalizedChunk = try await normalizer.normalizeToTemporaryWAV(chunk)
            guard let fileURL = normalizedChunk.fileURL else {
                throw AudioNormalizationError.invalidChunkFormat(
                    sampleRate: normalizedChunk.sampleRate,
                    channelCount: normalizedChunk.channelCount,
                    frameCount: normalizedChunk.frameCount
                )
            }
            defer {
                try? FileManager.default.removeItem(at: fileURL)
            }

            let result = try await engine.transcribe(audioFile: fileURL, mode: mode)
            let elapsed = Date().timeIntervalSince(started)
            append(result: result, elapsed: elapsed)
        } catch {
            handleLiveError(error)
        }

        isProcessingChunk = false
        if isRunning, errorMessage == nil {
            statusText = "Listening to computer audio and microphone..."
        }
    }

    private func append(result: TranscriptionResult, elapsed: Double) {
        lastInferenceDurationSeconds = elapsed

        let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            statusText = "No voice detected in the latest audio window."
            return
        }

        transcriptText = Self.appendDeduplicating(
            existing: transcriptText,
            addition: text
        )
        chunksTranscribed += 1
        latestLanguage = result.language ?? latestLanguage
        errorMessage = nil

        logger.info(
            "Live mixed transcription appended characters=\(text.count, privacy: .public), chunks=\(self.chunksTranscribed, privacy: .public), elapsedSeconds=\(elapsed, privacy: .public), language=\(result.language ?? "nil", privacy: .public)"
        )
    }

    private func handleLiveError(_ error: Error) {
        errorMessage = Self.userFacingMessage(for: error)
        statusText = isRunning
            ? "Live transcription hit an error; listening continues."
            : "Computer + mic transcription is stopped."
        logger.error("Live mixed transcription error: \(String(describing: error), privacy: .public)")
    }

    private func handleCaptureStreamEnded() async {
        guard isRunning else { return }
        isRunning = false
        isProcessingChunk = false
        captureTask = nil
        await captureService.stopCapture()
        statusText = "Computer + mic capture ended."
    }

    private nonisolated static func userFacingMessage(for error: Error) -> String {
        if let localizedError = error as? LocalizedError {
            let message = localizedError.errorDescription ?? error.localizedDescription
            let suggestion = localizedError.recoverySuggestion ?? ""
            return suggestion.isEmpty ? message : "\(message) \(suggestion)"
        }

        return error.localizedDescription
    }

    nonisolated static func appendDeduplicating(existing: String, addition: String) -> String {
        let trimmedAddition = addition.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedAddition.isEmpty else { return existing }

        let trimmedExisting = existing.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedExisting.isEmpty else { return trimmedAddition }
        guard trimmedExisting != trimmedAddition else { return trimmedExisting }

        let maxOverlapLength = min(160, trimmedExisting.count, trimmedAddition.count)
        if maxOverlapLength > 0 {
            for overlapLength in stride(from: maxOverlapLength, through: 1, by: -1) {
                let existingSuffix = String(trimmedExisting.suffix(overlapLength)).lowercased()
                let additionPrefix = String(trimmedAddition.prefix(overlapLength)).lowercased()

                if existingSuffix == additionPrefix {
                    let dropIndex = trimmedAddition.index(
                        trimmedAddition.startIndex,
                        offsetBy: overlapLength
                    )
                    let remainder = String(trimmedAddition[dropIndex...])
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    return remainder.isEmpty
                        ? trimmedExisting
                        : "\(trimmedExisting) \(remainder)"
                }
            }
        }

        return "\(trimmedExisting) \(trimmedAddition)"
    }

    #if DEBUG
    nonisolated static func runStateSmokeCheck() {
        assert(
            appendDeduplicating(existing: "", addition: "hello") == "hello",
            "Expected empty transcript to adopt addition"
        )
        assert(
            appendDeduplicating(existing: "hello world", addition: "world again") == "hello world again",
            "Expected overlapping transcript chunks to be deduplicated"
        )
        assert(
            appendDeduplicating(existing: "same", addition: "same") == "same",
            "Expected identical transcript chunks to avoid duplication"
        )
    }
    #endif
}
