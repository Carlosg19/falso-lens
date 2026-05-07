import Foundation
import OSLog

actor WhisperCppEngine: TranscriptionEngine {
    private let executableURL: URL
    private let modelURL: URL
    private let deletesJSONSidecarOnSuccess: Bool

    private nonisolated static let bundledExecutableName = "whisper-cli"
    private nonisolated static let bundledModelResourceName = "ggml-small"
    private nonisolated static let bundledModelResourceExtension = "bin"

    private nonisolated static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.falsoai.FalsoaiLens",
        category: "WhisperEngine"
    )

    init(
        executableURL: URL? = nil,
        modelURL: URL? = nil,
        deletesJSONSidecarOnSuccess: Bool = true
    ) throws {
        let resolvedExecutableURL = try executableURL ?? Self.resolveBundledExecutable()
        let resolvedModelURL = try modelURL ?? Self.resolveBundledModel()

        guard FileManager.default.isExecutableFile(atPath: resolvedExecutableURL.path) else {
            Self.logger.error("Bundled whisper-cli is not executable path=\(resolvedExecutableURL.path, privacy: .public)")
            throw WhisperEngineError.missingExecutable
        }

        self.executableURL = resolvedExecutableURL
        self.modelURL = resolvedModelURL
        self.deletesJSONSidecarOnSuccess = deletesJSONSidecarOnSuccess

        Self.logger.info(
            "WhisperCppEngine initialized executable=\(resolvedExecutableURL.path, privacy: .public), model=\(resolvedModelURL.path, privacy: .public), deletesSidecarOnSuccess=\(deletesJSONSidecarOnSuccess, privacy: .public)"
        )
    }

    func transcribe(
        audioFile: URL,
        mode: TranscriptionMode
    ) async throws -> TranscriptionResult {
        try Self.validateAudioFile(audioFile)

        let outputPrefix = NSTemporaryDirectory()
            + "whisper-output-\(UUID().uuidString)"
        let jsonURL = URL(fileURLWithPath: outputPrefix + ".json")
        defer {
            if deletesJSONSidecarOnSuccess {
                try? FileManager.default.removeItem(at: jsonURL)
            }
        }

        let result = try await runWhisper(
            audioFile: audioFile,
            mode: mode,
            outputPrefix: outputPrefix
        )

        guard result.exitCode == 0 else {
            Self.logger.error(
                "whisper-cli failed exitCode=\(result.exitCode, privacy: .public), stderrLength=\(result.stderr.count, privacy: .public)"
            )
            throw WhisperEngineError.processFailed(
                exitCode: result.exitCode,
                stderr: result.stderr
            )
        }

        Self.logger.info(
            "whisper-cli completed jsonSidecar=\(jsonURL.path, privacy: .public), stdoutLength=\(result.stdout.count, privacy: .public)"
        )

        let jsonData: Data
        do {
            jsonData = try Data(contentsOf: jsonURL)
        } catch {
            Self.logger.error(
                "Could not read whisper JSON sidecar at \(jsonURL.path, privacy: .public): \(String(describing: error), privacy: .public)"
            )
            throw WhisperEngineError.invalidJSONOutput("could not read \(jsonURL.lastPathComponent): \(error.localizedDescription)")
        }

        return try Self.decodeTranscriptionResult(from: jsonData)
    }

    nonisolated static func decodeTranscriptionResult(from data: Data) throws -> TranscriptionResult {
        let decoder = JSONDecoder()
        let raw: RawWhisperOutput
        do {
            raw = try decoder.decode(RawWhisperOutput.self, from: data)
        } catch {
            let snippet = (String(data: data.prefix(160), encoding: .utf8) ?? "<non-utf8 bytes>")
                .replacingOccurrences(of: "\n", with: " ")
            logger.error(
                "Failed to decode whisper JSON: \(String(describing: error), privacy: .public). snippet=\(snippet, privacy: .public)"
            )
            throw WhisperEngineError.invalidJSONOutput(snippet)
        }

        let segments: [TranscriptSegment] = raw.transcription.map { rawSegment in
            TranscriptSegment(
                startTime: parseWhisperTimestamp(rawSegment.timestamps.from),
                endTime: parseWhisperTimestamp(rawSegment.timestamps.to),
                text: rawSegment.text
            )
        }

        let combinedText = raw.transcription
            .map(\.text)
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let duration = segments.last?.endTime
        let language = raw.result?.language

        return TranscriptionResult(
            text: combinedText,
            segments: segments,
            language: language,
            duration: duration
        )
    }

    nonisolated static func parseWhisperTimestamp(_ raw: String) -> TimeInterval? {
        let components = raw.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
        guard components.count == 3 else { return nil }
        guard let hours = Int(components[0]), let minutes = Int(components[1]) else { return nil }
        let secondsPart = components[2].replacingOccurrences(of: ",", with: ".")
        guard let seconds = Double(secondsPart) else { return nil }
        return TimeInterval(hours * 3600) + TimeInterval(minutes * 60) + seconds
    }

    private struct RawWhisperOutput: Decodable {
        struct Result: Decodable {
            let language: String?
        }
        struct Transcription: Decodable {
            let timestamps: Timestamps
            let text: String
        }
        struct Timestamps: Decodable {
            let from: String
            let to: String
        }
        let result: Result?
        let transcription: [Transcription]
    }

    #if DEBUG
    nonisolated static func runParserSmokeCheck() {
        guard let url = Bundle.main.url(
            forResource: "whisper-fixture",
            withExtension: "json"
        ) else {
            logger.error("Parser smoke check skipped: whisper-fixture.json not bundled")
            return
        }
        do {
            let data = try Data(contentsOf: url)
            let result = try decodeTranscriptionResult(from: data)
            assert(
                result.text.contains("Hello world"),
                "Parser smoke check: expected text to contain 'Hello world', got '\(result.text)'"
            )
            assert(
                result.segments.count == 2,
                "Parser smoke check: expected 2 segments, got \(result.segments.count)"
            )
            assert(
                result.language == "en",
                "Parser smoke check: expected language 'en', got '\(result.language ?? "nil")'"
            )
            assert(
                result.duration == 5.0,
                "Parser smoke check: expected duration 5.0, got \(String(describing: result.duration))"
            )
            logger.info("✅ Parser smoke check passed text=\"\(result.text, privacy: .public)\", segments=\(result.segments.count, privacy: .public), language=\(result.language ?? "nil", privacy: .public), duration=\(result.duration ?? -1, privacy: .public)")
        } catch {
            assertionFailure("Parser smoke check failed: \(error)")
        }
    }
    #endif

    private struct ProcessInvocationResult {
        let exitCode: Int32
        let stderr: String
        let stdout: String
    }

    private static func validateAudioFile(_ audioFile: URL) throws {
        let path = audioFile.path
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: path) else {
            throw WhisperEngineError.audioFileNotFound(audioFile)
        }
        let attributes = try fileManager.attributesOfItem(atPath: path)
        let size = (attributes[.size] as? NSNumber)?.intValue ?? 0
        guard size > 0 else {
            throw WhisperEngineError.audioFileEmpty(audioFile)
        }
    }

    private func runWhisper(
        audioFile: URL,
        mode: TranscriptionMode,
        outputPrefix: String
    ) async throws -> ProcessInvocationResult {
        var arguments: [String] = [
            "-m", modelURL.path,
            "-f", audioFile.path,
            "-oj",
            "-of", outputPrefix,
            "-nt",
        ]
        if mode == .translateToEnglish {
            arguments.append("-tr")
        }

        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let stdoutBuffer = AsyncDataAccumulator()
        let stderrBuffer = AsyncDataAccumulator()

        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty {
                stdoutBuffer.append(data)
            }
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty {
                stderrBuffer.append(data)
            }
        }

        Self.logger.info(
            "whisper-cli launching mode=\(String(describing: mode), privacy: .public), arguments=\(arguments.joined(separator: " "), privacy: .public)"
        )
        let start = Date()

        do {
            try process.run()
        } catch {
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            Self.logger.error("Failed to launch whisper-cli: \(String(describing: error), privacy: .public)")
            throw WhisperEngineError.processFailed(
                exitCode: -1,
                stderr: "Could not launch whisper-cli: \(error.localizedDescription)"
            )
        }

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            process.terminationHandler = { _ in
                continuation.resume()
            }
        }

        // Drain any remaining data after exit.
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil
        let trailingStdout = stdoutPipe.fileHandleForReading.availableData
        if !trailingStdout.isEmpty {
            stdoutBuffer.append(trailingStdout)
        }
        let trailingStderr = stderrPipe.fileHandleForReading.availableData
        if !trailingStderr.isEmpty {
            stderrBuffer.append(trailingStderr)
        }

        let elapsed = Date().timeIntervalSince(start)
        Self.logger.info(
            "whisper-cli exit status=\(process.terminationStatus, privacy: .public), elapsedSeconds=\(elapsed, privacy: .public), stdoutBytes=\(stdoutBuffer.byteCount, privacy: .public), stderrBytes=\(stderrBuffer.byteCount, privacy: .public)"
        )

        return ProcessInvocationResult(
            exitCode: process.terminationStatus,
            stderr: stderrBuffer.makeString(),
            stdout: stdoutBuffer.makeString()
        )
    }

    private nonisolated static func resolveBundledExecutable() throws -> URL {
        if let url = Bundle.main.url(
            forResource: bundledExecutableName,
            withExtension: nil
        ) {
            return url
        }
        logger.error("Could not find bundled whisper-cli (resource name=\(bundledExecutableName, privacy: .public))")
        throw WhisperEngineError.missingExecutable
    }

    private nonisolated static func resolveBundledModel() throws -> URL {
        if let url = Bundle.main.url(
            forResource: bundledModelResourceName,
            withExtension: bundledModelResourceExtension
        ) {
            return url
        }
        logger.error("Could not find bundled \(bundledModelResourceName, privacy: .public).\(bundledModelResourceExtension, privacy: .public)")
        throw WhisperEngineError.missingModel
    }
}

private final class AsyncDataAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    var byteCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return data.count
    }

    func append(_ chunk: Data) {
        lock.lock()
        data.append(chunk)
        lock.unlock()
    }

    func makeString() -> String {
        lock.lock()
        defer { lock.unlock() }
        return String(data: data, encoding: .utf8) ?? ""
    }
}
