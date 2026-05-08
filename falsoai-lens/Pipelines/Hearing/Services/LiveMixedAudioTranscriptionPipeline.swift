import Combine
import Foundation
import OSLog
import SwiftUI

private struct SourceTranscriptionOutput: Sendable {
    let source: CapturedAudioSource
    let result: TranscriptionResult
    let elapsed: Double
    let errorMessage: String?

    nonisolated var trimmedText: String {
        result.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    nonisolated func assigningSource(_ source: CapturedAudioSource) -> SourceTranscriptionOutput {
        SourceTranscriptionOutput(
            source: source,
            result: result,
            elapsed: elapsed,
            errorMessage: errorMessage
        )
    }

}

@MainActor
final class LiveMixedAudioTranscriptionPipeline: ObservableObject {
    @Published private(set) var isRunning = false
    @Published private(set) var isProcessingChunk = false
    @Published private(set) var statusText = "Computer + mic transcription is stopped."
    @Published private(set) var errorMessage: String?
    @Published private(set) var computerTranscript = SourceTranscriptState(source: .computer)
    @Published private(set) var microphoneTranscript = SourceTranscriptState(source: .microphone)

    private let captureService: ComputerMicrophoneAudioCaptureService
    private let mixer: MixedAudioBufferStore?
    private let normalizer: AudioNormalizer?
    private let microphoneEngine: TranscriptionEngine?
    private let computerEngine: TranscriptionEngine?
    private let logger: Logger
    private var captureTask: Task<Void, Never>?

    init(
        captureService: ComputerMicrophoneAudioCaptureService? = nil,
        mixer: MixedAudioBufferStore? = nil,
        normalizer: AudioNormalizer? = nil,
        microphoneEngine: TranscriptionEngine? = nil,
        computerEngine: TranscriptionEngine? = nil,
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
            self.microphoneEngine = engine
            self.computerEngine = engine
        } else {
            self.microphoneEngine = microphoneEngine ?? Self.makeDefaultEngine(
                source: .microphone,
                logger: logger
            )
            self.computerEngine = computerEngine ?? Self.makeDefaultEngine(
                source: .computer,
                logger: logger
            )
        }

        if self.mixer == nil {
            errorMessage = "Mixed audio buffer could not be initialized."
        }
        if self.normalizer == nil {
            errorMessage = "Audio normalizer could not be initialized."
        }
        if self.microphoneEngine == nil || self.computerEngine == nil {
            errorMessage = "Whisper engine unavailable."
        }
    }

    var isEngineAvailable: Bool {
        microphoneEngine != nil && computerEngine != nil && mixer != nil && normalizer != nil
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
            logger.error("Live mixed pipeline could not construct \(source.rawValue, privacy: .public) engine: \(message, privacy: .public). \(suggestion, privacy: .public)")
            return nil
        } catch {
            logger.error("Live mixed pipeline failed to construct \(source.rawValue, privacy: .public) engine: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    func start(mode: TranscriptionMode) async {
        guard !isRunning else { return }
        guard let mixer, let normalizer, let microphoneEngine, let computerEngine else {
            errorMessage = errorMessage ?? "Live transcription is not available."
            return
        }

        await mixer.clear()
        computerTranscript = SourceTranscriptState(source: .computer)
        microphoneTranscript = SourceTranscriptState(source: .microphone)
        errorMessage = nil
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
        statusText = "Listening to separated computer and microphone audio..."

        captureTask = Task.detached(priority: .userInitiated) { [weak self, mixer, normalizer, microphoneEngine, computerEngine, stream, mode] in
            for await packet in stream {
                if Task.isCancelled { break }

                do {
                    let batches = try await mixer.append(packet)
                    for batch in batches {
                        if Task.isCancelled { break }
                        await self?.transcribe(
                            batch: batch,
                            normalizer: normalizer,
                            microphoneEngine: microphoneEngine,
                            computerEngine: computerEngine,
                            mode: mode
                        )
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
        statusText = totalChunksTranscribed > 0
            ? "Stopped after \(totalChunksTranscribed) transcript chunks."
            : "Computer + mic transcription is stopped."

        logger.info("Live mixed transcription stopped chunks=\(self.totalChunksTranscribed, privacy: .public)")
    }

    func clearTranscript() {
        computerTranscript = SourceTranscriptState(source: .computer)
        microphoneTranscript = SourceTranscriptState(source: .microphone)
        errorMessage = nil
        statusText = isRunning
            ? "Listening to separated computer and microphone audio..."
            : "Computer + mic transcription is stopped."
    }

    var hasTranscriptText: Bool {
        !computerTranscript.isEmpty || !microphoneTranscript.isEmpty
    }

    var totalChunksTranscribed: Int {
        computerTranscript.chunksTranscribed + microphoneTranscript.chunksTranscribed
    }

    var combinedTranscriptText: String {
        [
            formattedTranscriptBlock(title: "Computer Audio", text: computerTranscript.text),
            formattedTranscriptBlock(title: "Microphone", text: microphoneTranscript.text)
        ]
        .compactMap { $0 }
        .joined(separator: "\n\n")
    }

    private func transcribe(
        batch: SeparatedAudioChunkBatch,
        normalizer: AudioNormalizer,
        microphoneEngine: TranscriptionEngine,
        computerEngine: TranscriptionEngine,
        mode: TranscriptionMode
    ) async {
        isProcessingChunk = true
        statusText = "Transcribing recent separated audio..."

        var outputs: [SourceTranscriptionOutput] = []

        await withTaskGroup(of: SourceTranscriptionOutput.self) { group in
            for chunk in batch.chunksInProcessingOrder {
                let engine = chunk.source == .microphone ? microphoneEngine : computerEngine
                group.addTask {
                    await Self.transcribeOutput(
                        chunk: chunk,
                        normalizer: normalizer,
                        engine: engine,
                        mode: mode
                    )
                }
            }

            for await output in group {
                outputs.append(output)
            }
        }

        let errors = outputs.compactMap(\.errorMessage)
        if let firstError = errors.first {
            errorMessage = firstError
            logger.error("Live concurrent transcription error: \(firstError, privacy: .public)")
        }

        let resolvedOutputs = Self.resolveSourceOwnership(
            outputs,
            microphoneChunk: batch.microphone,
            computerChunk: batch.computer
        )

        for source in [CapturedAudioSource.microphone, .computer] {
            for output in resolvedOutputs where output.source == source {
                append(
                    result: output.result,
                    source: output.source,
                    elapsed: output.elapsed
                )
            }
        }

        isProcessingChunk = false
        if isRunning, errorMessage == nil {
            statusText = "Listening to separated computer and microphone audio..."
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
                source: chunk.source,
                result: result,
                elapsed: Date().timeIntervalSince(started),
                errorMessage: nil
            )
        } catch {
            return SourceTranscriptionOutput(
                source: chunk.source,
                result: TranscriptionResult(text: "", segments: [], language: nil, duration: 0),
                elapsed: Date().timeIntervalSince(started),
                errorMessage: Self.userFacingMessage(for: error)
            )
        }
    }

    private nonisolated static func resolveSourceOwnership(
        _ outputs: [SourceTranscriptionOutput],
        microphoneChunk: BufferedAudioChunk?,
        computerChunk: BufferedAudioChunk?
    ) -> [SourceTranscriptionOutput] {
        guard let microphoneOutput = outputs.first(where: { $0.source == .microphone }),
              let computerOutput = outputs.first(where: { $0.source == .computer }),
              !computerOutput.trimmedText.isEmpty
        else {
            return outputs
        }

        if !microphoneOutput.trimmedText.isEmpty,
           isLikelySameUtterance(computerOutput.trimmedText, microphoneOutput.trimmedText) {
            return outputs.filter { $0.source != .computer }
        }

        guard microphoneOutput.trimmedText.isEmpty,
              let microphoneChunk,
              sourceChunkLooksActive(microphoneChunk),
              computerChunk == nil || sourceChunkLooksLeakedFromMicrophone(
                  microphoneChunk: microphoneChunk,
                  computerChunk: computerChunk
              )
        else {
            return outputs
        }

        return outputs.compactMap { output in
            switch output.source {
            case .microphone:
                return computerOutput.assigningSource(.microphone)
            case .computer:
                return nil
            }
        }
    }

    private func append(result: TranscriptionResult, source: CapturedAudioSource, elapsed: Double) {
        var state = transcriptState(for: source)
        state.lastInferenceDurationSeconds = elapsed

        let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            setTranscriptState(state)
            statusText = "No voice detected in the latest \(source.displayName.lowercased()) audio window."
            return
        }

        state.text = Self.appendDeduplicating(
            existing: state.text,
            addition: text
        )
        state.chunksTranscribed += 1
        state.latestLanguage = result.language ?? state.latestLanguage
        setTranscriptState(state)
        errorMessage = nil

        logger.info(
            "Live separated transcription appended source=\(source.rawValue, privacy: .public), characters=\(text.count, privacy: .public), chunks=\(state.chunksTranscribed, privacy: .public), elapsedSeconds=\(elapsed, privacy: .public), language=\(result.language ?? "nil", privacy: .public)"
        )
    }

    private func transcriptState(for source: CapturedAudioSource) -> SourceTranscriptState {
        switch source {
        case .computer:
            return computerTranscript
        case .microphone:
            return microphoneTranscript
        }
    }

    private func setTranscriptState(_ state: SourceTranscriptState) {
        switch state.source {
        case .computer:
            computerTranscript = state
        case .microphone:
            microphoneTranscript = state
        }
    }

    private func formattedTranscriptBlock(title: String, text: String) -> String? {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else { return nil }
        return "\(title):\n\(trimmedText)"
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

    nonisolated static func isLikelySameUtterance(_ lhs: String, _ rhs: String?) -> Bool {
        guard let rhs else { return false }

        let lhsWords = normalizedWords(lhs)
        let rhsWords = normalizedWords(rhs)
        guard !lhsWords.isEmpty, !rhsWords.isEmpty else { return false }

        let lhsJoined = lhsWords.joined(separator: " ")
        let rhsJoined = rhsWords.joined(separator: " ")
        if lhsJoined == rhsJoined {
            return true
        }

        let shorter = lhsJoined.count <= rhsJoined.count ? lhsJoined : rhsJoined
        let longer = lhsJoined.count > rhsJoined.count ? lhsJoined : rhsJoined
        if shorter.count >= 24, longer.contains(shorter) {
            return true
        }

        let lhsSet = Set(lhsWords)
        let rhsSet = Set(rhsWords)
        let overlapCount = lhsSet.intersection(rhsSet).count
        let smallerCount = min(lhsSet.count, rhsSet.count)
        guard smallerCount >= 4 else { return false }

        return Double(overlapCount) / Double(smallerCount) >= 0.82
    }

    nonisolated static func removingTrailingUtterance(_ utterance: String, from transcript: String) -> String {
        let trimmedTranscript = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedUtterance = utterance.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTranscript.isEmpty, !trimmedUtterance.isEmpty else {
            return trimmedTranscript
        }

        if trimmedTranscript.hasSuffix(trimmedUtterance) {
            let endIndex = trimmedTranscript.index(
                trimmedTranscript.endIndex,
                offsetBy: -trimmedUtterance.count
            )
            return String(trimmedTranscript[..<endIndex])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let utteranceWordCount = normalizedWords(trimmedUtterance).count
        let transcriptWords = trimmedTranscript.split(whereSeparator: { $0.isWhitespace })
        if utteranceWordCount > 0, transcriptWords.count >= utteranceWordCount {
            let trailingWords = transcriptWords
                .suffix(utteranceWordCount)
                .joined(separator: " ")

            if isLikelySameUtterance(trailingWords, trimmedUtterance) {
                return transcriptWords
                    .dropLast(utteranceWordCount)
                    .joined(separator: " ")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        guard isLikelySameUtterance(trimmedTranscript, trimmedUtterance) else {
            return trimmedTranscript
        }

        return ""
    }

    private nonisolated static func sourceChunkLooksActive(_ chunk: BufferedAudioChunk) -> Bool {
        guard !chunk.samples.isEmpty else { return false }
        return rmsDBFS(for: chunk.samples) >= -52 || peakAmplitude(for: chunk.samples) >= 0.02
    }

    private nonisolated static func sourceChunkLooksLeakedFromMicrophone(
        microphoneChunk: BufferedAudioChunk,
        computerChunk: BufferedAudioChunk?
    ) -> Bool {
        guard let computerChunk, !computerChunk.samples.isEmpty else { return true }

        let microphoneRMS = rmsDBFS(for: microphoneChunk.samples)
        let computerRMS = rmsDBFS(for: computerChunk.samples)
        if computerRMS < -58 {
            return true
        }

        if microphoneRMS >= computerRMS - 10 {
            return true
        }

        return absoluteCorrelation(
            microphoneChunk.samples,
            computerChunk.samples
        ) >= 0.35
    }

    private nonisolated static func rmsDBFS(for samples: [Float]) -> Double {
        guard !samples.isEmpty else { return -.infinity }
        let squareSum = samples.reduce(Double.zero) { partialResult, sample in
            partialResult + Double(sample * sample)
        }
        let rms = sqrt(squareSum / Double(samples.count))
        guard rms > 0 else { return -.infinity }
        return 20 * log10(rms)
    }

    private nonisolated static func peakAmplitude(for samples: [Float]) -> Float {
        samples.reduce(Float.zero) { partialResult, sample in
            max(partialResult, abs(sample))
        }
    }

    private nonisolated static func absoluteCorrelation(_ lhs: [Float], _ rhs: [Float]) -> Double {
        let count = min(lhs.count, rhs.count)
        guard count > 0 else { return 0 }

        var dotProduct = 0.0
        var lhsEnergy = 0.0
        var rhsEnergy = 0.0

        for index in 0..<count {
            let lhsSample = Double(lhs[index])
            let rhsSample = Double(rhs[index])
            dotProduct += lhsSample * rhsSample
            lhsEnergy += lhsSample * lhsSample
            rhsEnergy += rhsSample * rhsSample
        }

        guard lhsEnergy > 0, rhsEnergy > 0 else { return 0 }
        return abs(dotProduct / sqrt(lhsEnergy * rhsEnergy))
    }

    private nonisolated static func normalizedWords(_ text: String) -> [String] {
        let foldedText = text.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: .current
        )
        let allowedCharacters = CharacterSet.alphanumerics.union(.whitespacesAndNewlines)
        let cleanedScalars = foldedText.unicodeScalars.map { scalar in
            allowedCharacters.contains(scalar) ? Character(scalar) : " "
        }

        return String(cleanedScalars)
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
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
            computer.text == "desktop speech" && microphone.text == "mic speech",
            "Expected source transcript states to stay independent"
        )
        assert(
            isLikelySameUtterance("hello from the microphone", "Hello, from the microphone."),
            "Expected transcript source comparison to ignore punctuation and case"
        )
        assert(
            removingTrailingUtterance("hello from the microphone", from: "hello from the microphone") == "",
            "Expected duplicate source text to be removable when microphone owns it"
        )
    }
    #endif
}
