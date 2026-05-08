import Combine
import CoreAudio
import Foundation
import OSLog

@MainActor
final class LiveAudioTranscriptionPipeline: ObservableObject {
    @Published private(set) var isRunning = false
    @Published private(set) var isProcessingChunk = false
    @Published private(set) var statusText: String
    @Published private(set) var errorMessage: String?
    @Published private(set) var transcript: SourceTranscriptState

    private let source: CapturedAudioSource
    private let captureProvider: any LiveAudioCaptureProvider
    private let chunker: AudioChunker?
    private let normalizer: AudioNormalizer?
    private let engine: TranscriptionEngine?
    private let logger: Logger
    private var captureTask: Task<Void, Never>?
    private var chunkHook: (@Sendable (LiveTranscriptChunkEvent) -> Void)?

    static func computer() -> LiveAudioTranscriptionPipeline {
        LiveAudioTranscriptionPipeline(
            source: .computer,
            captureProvider: ComputerAudioCaptureService()
        )
    }

    static func microphone() -> LiveAudioTranscriptionPipeline {
        LiveAudioTranscriptionPipeline(
            source: .microphone,
            captureProvider: MicrophoneAudioCaptureProvider()
        )
    }

    init(
        source: CapturedAudioSource,
        captureProvider: (any LiveAudioCaptureProvider)? = nil,
        chunker: AudioChunker? = nil,
        normalizer: AudioNormalizer? = nil,
        engine: TranscriptionEngine? = nil,
        logger: Logger? = nil
    ) {
        self.source = source
        self.captureProvider = captureProvider ?? Self.makeDefaultCaptureProvider(for: source)
        self.logger = logger ?? Logger(
            subsystem: Bundle.main.bundleIdentifier ?? "com.falsoai.FalsoaiLens",
            category: "Live\(source.displayName)AudioTranscription"
        )
        self.statusText = "\(source.displayName) transcription is stopped."
        self.transcript = SourceTranscriptState(source: source)

        if let chunker {
            self.chunker = chunker
        } else {
            self.chunker = try? AudioChunker(source: source)
        }

        if let normalizer {
            self.normalizer = normalizer
        } else {
            self.normalizer = try? AudioNormalizer()
        }

        self.engine = engine ?? Self.makeDefaultEngine(source: source, logger: self.logger)

        if self.chunker == nil {
            errorMessage = "\(source.displayName) audio buffer could not be initialized."
        }
        if self.normalizer == nil {
            errorMessage = "Audio normalizer could not be initialized."
        }
        if self.engine == nil {
            errorMessage = "Whisper engine unavailable."
        }
    }

    var isAvailable: Bool {
        chunker != nil && normalizer != nil && engine != nil
    }

    var hasTranscriptText: Bool {
        !transcript.isEmpty
    }

    var transcriptSource: TranscriptSource {
        captureProvider.transcriptSource
    }

    func setInputDeviceID(_ deviceID: AudioDeviceID?) {
        guard !isRunning else { return }
        captureProvider.setInputDeviceID(deviceID)

        if source == .microphone {
            statusText = "\(source.displayName) input device selected."
        }
    }

    func setChunkHook(_ hook: (@Sendable (LiveTranscriptChunkEvent) -> Void)?) {
        self.chunkHook = hook
    }

    private static func makeDefaultCaptureProvider(
        for source: CapturedAudioSource
    ) -> any LiveAudioCaptureProvider {
        switch source {
        case .computer:
            return ComputerAudioCaptureService()
        case .microphone:
            return MicrophoneAudioCaptureProvider()
        }
    }

    private static func makeDefaultEngine(
        source: CapturedAudioSource,
        logger: Logger
    ) -> TranscriptionEngine? {
        do {
            return try WhisperCppEngine()
        } catch let error as WhisperEngineError {
            let message = error.errorDescription ?? "Whisper engine unavailable."
            let suggestion = error.recoverySuggestion ?? ""
            logger.error("\(source.rawValue, privacy: .public) pipeline could not construct engine: \(message, privacy: .public). \(suggestion, privacy: .public)")
            return nil
        } catch {
            logger.error("\(source.rawValue, privacy: .public) pipeline failed to construct engine: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    func start(mode: TranscriptionMode) async {
        guard !isRunning else { return }
        guard let chunker, let normalizer, let engine else {
            errorMessage = errorMessage ?? "\(source.displayName) live transcription is not available."
            return
        }

        await chunker.clear()
        transcript = SourceTranscriptState(source: source)
        errorMessage = nil
        isProcessingChunk = false
        statusText = "Starting \(source.displayName.lowercased()) capture..."

        let stream: AsyncStream<CapturedAudioBuffer>
        do {
            stream = try await captureProvider.startCapture()
        } catch {
            errorMessage = Self.userFacingMessage(for: error)
            statusText = "\(source.displayName) transcription could not start."
            logger.error("\(self.source.rawValue, privacy: .public) capture failed to start: \(String(describing: error), privacy: .public)")
            return
        }

        isRunning = true
        statusText = "Listening to \(source.displayName.lowercased()) audio..."

        captureTask = Task.detached(priority: .userInitiated) { [weak self, chunker, normalizer, engine, stream, mode, source] in
            for await buffer in stream {
                if Task.isCancelled { break }

                do {
                    let chunks = try await chunker.append(buffer)
                    for chunk in chunks {
                        if Task.isCancelled { break }
                        await self?.transcribe(
                            chunk: chunk,
                            normalizer: normalizer,
                            engine: engine,
                            mode: mode
                        )
                    }
                } catch {
                    await self?.handleLiveError(error)
                }
            }

            await self?.handleCaptureStreamEnded()
            Self.logCaptureTaskEnded(source: source)
        }

        logger.info("\(self.source.rawValue, privacy: .public) live transcription started mode=\(String(describing: mode), privacy: .public)")
    }

    func stop() async {
        captureTask?.cancel()
        captureTask = nil
        await captureProvider.stopCapture()
        await chunker?.clear()

        isRunning = false
        isProcessingChunk = false
        statusText = transcript.chunksTranscribed > 0
            ? "\(source.displayName) stopped after \(transcript.chunksTranscribed) transcript chunks."
            : "\(source.displayName) transcription is stopped."

        logger.info("\(self.source.rawValue, privacy: .public) live transcription stopped chunks=\(self.transcript.chunksTranscribed, privacy: .public)")
    }

    func clearTranscript() {
        transcript = SourceTranscriptState(source: source)
        errorMessage = nil
        statusText = isRunning
            ? "Listening to \(source.displayName.lowercased()) audio..."
            : "\(source.displayName) transcription is stopped."
    }

    private func transcribe(
        chunk: BufferedAudioChunk,
        normalizer: AudioNormalizer,
        engine: TranscriptionEngine,
        mode: TranscriptionMode
    ) async {
        assert(chunk.source == source, "A live audio pipeline can only transcribe chunks for its configured source.")

        isProcessingChunk = true
        statusText = "Transcribing recent \(source.displayName.lowercased()) audio..."

        let output = await Self.transcribeOutput(
            chunk: chunk,
            normalizer: normalizer,
            engine: engine,
            mode: mode
        )

        if let errorMessage = output.errorMessage {
            self.errorMessage = errorMessage
            logger.error("\(self.source.rawValue, privacy: .public) transcription error: \(errorMessage, privacy: .public)")
        } else {
            append(
                result: output.result,
                chunk: chunk,
                normalizedSamples: output.normalizedSamples,
                normalizedSampleRate: output.normalizedSampleRate,
                elapsed: output.elapsed
            )
        }

        isProcessingChunk = false
        if isRunning, self.errorMessage == nil {
            statusText = "Listening to \(source.displayName.lowercased()) audio..."
        }
    }

    private nonisolated static func transcribeOutput(
        chunk: BufferedAudioChunk,
        normalizer: AudioNormalizer,
        engine: TranscriptionEngine,
        mode: TranscriptionMode
    ) async -> SourceTranscriptionOutput {
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
            return SourceTranscriptionOutput(
                result: result,
                normalizedSamples: normalizedChunk.samples,
                normalizedSampleRate: normalizedChunk.sampleRate,
                elapsed: Date().timeIntervalSince(started),
                errorMessage: nil
            )
        } catch {
            return SourceTranscriptionOutput(
                result: TranscriptionResult(text: "", segments: [], language: nil, duration: 0),
                normalizedSamples: [],
                normalizedSampleRate: 0,
                elapsed: Date().timeIntervalSince(started),
                errorMessage: Self.userFacingMessage(for: error)
            )
        }
    }

    private func append(
        result: TranscriptionResult,
        chunk: BufferedAudioChunk,
        normalizedSamples: [Float],
        normalizedSampleRate: Double,
        elapsed: Double
    ) {
        transcript.lastInferenceDurationSeconds = elapsed

        let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            statusText = "No voice detected in the latest \(source.displayName.lowercased()) audio window."
            return
        }

        let transcriptChunk = Self.makeTranscriptChunk(
            source: source,
            chunk: chunk,
            result: result,
            text: text
        )

        transcript.chunks.append(transcriptChunk)
        transcript.text = Self.appendDeduplicating(
            existing: transcript.text,
            addition: text
        )
        transcript.chunksTranscribed += 1
        transcript.latestLanguage = result.language ?? transcript.latestLanguage
        errorMessage = nil

        logger.info(
            "\(self.source.rawValue, privacy: .public) transcription appended characters=\(text.count, privacy: .public), chunks=\(self.transcript.chunksTranscribed, privacy: .public), elapsedSeconds=\(elapsed, privacy: .public), language=\(result.language ?? "nil", privacy: .public)"
        )

        if let chunkHook, !normalizedSamples.isEmpty, normalizedSampleRate > 0 {
            let event = LiveTranscriptChunkEvent(
                chunk: transcriptChunk,
                normalizedSamples: normalizedSamples,
                normalizedSampleRate: normalizedSampleRate
            )
            chunkHook(event)
        }
    }

    private nonisolated static func makeTranscriptChunk(
        source: CapturedAudioSource,
        chunk: BufferedAudioChunk,
        result: TranscriptionResult,
        text: String
    ) -> SourceTranscriptChunk {
        let startTime = Double(chunk.startFrame) / chunk.sampleRate
        let duration = chunk.sampleRate > 0
            ? Double(chunk.frameCount) / chunk.sampleRate
            : 0
        let endTime = startTime + duration
        let chunkID = "\(source.rawValue)_\(String(format: "%03d", chunk.sequenceNumber))"

        let segments = result.segments.compactMap { segment -> SourceTranscriptSegment? in
            let segmentText = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !segmentText.isEmpty else { return nil }

            let relativeStart = max(0, segment.startTime ?? 0)
            let relativeEnd = max(relativeStart, segment.endTime ?? relativeStart)

            return SourceTranscriptSegment(
                startTime: startTime + relativeStart,
                endTime: startTime + relativeEnd,
                text: segmentText
            )
        }

        return SourceTranscriptChunk(
            chunkID: chunkID,
            source: source,
            sequenceNumber: chunk.sequenceNumber,
            startTime: startTime,
            endTime: endTime,
            duration: duration,
            language: result.language,
            text: text,
            segments: segments
        )
    }

    private func handleLiveError(_ error: Error) {
        errorMessage = Self.userFacingMessage(for: error)
        statusText = isRunning
            ? "\(source.displayName) transcription hit an error; listening continues."
            : "\(source.displayName) transcription is stopped."
        logger.error("\(self.source.rawValue, privacy: .public) live transcription error: \(String(describing: error), privacy: .public)")
    }

    private func handleCaptureStreamEnded() async {
        guard isRunning else { return }
        isRunning = false
        isProcessingChunk = false
        captureTask = nil
        await captureProvider.stopCapture()
        statusText = "\(source.displayName) capture ended."
    }

    private nonisolated static func userFacingMessage(for error: Error) -> String {
        if let localizedError = error as? LocalizedError {
            let message = localizedError.errorDescription ?? error.localizedDescription
            let suggestion = localizedError.recoverySuggestion ?? ""
            return suggestion.isEmpty ? message : "\(message) \(suggestion)"
        }

        return error.localizedDescription
    }

    private nonisolated static func logCaptureTaskEnded(source: CapturedAudioSource) {
        let logger = Logger(
            subsystem: Bundle.main.bundleIdentifier ?? "com.falsoai.FalsoaiLens",
            category: "Live\(source.displayName)AudioTranscription"
        )
        logger.info("\(source.rawValue, privacy: .public) capture task ended")
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

        var computer = SourceTranscriptState(source: .computer)
        var microphone = SourceTranscriptState(source: .microphone)
        computer.text = appendDeduplicating(existing: computer.text, addition: "desktop speech")
        microphone.text = appendDeduplicating(existing: microphone.text, addition: "mic speech")
        assert(
            computer.source == .computer
                && microphone.source == .microphone
                && computer.text == "desktop speech"
                && microphone.text == "mic speech",
            "Expected source transcript states to stay independent"
        )
    }
    #endif
}

private struct SourceTranscriptionOutput: Sendable {
    let result: TranscriptionResult
    let normalizedSamples: [Float]
    let normalizedSampleRate: Double
    let elapsed: Double
    let errorMessage: String?
}
