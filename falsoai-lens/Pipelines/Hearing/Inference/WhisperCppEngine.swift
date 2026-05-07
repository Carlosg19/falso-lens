import Foundation
import OSLog

actor WhisperCppEngine: TranscriptionEngine {
    private let executableURL: URL
    private let modelURL: URL
    private let deletesJSONSidecarOnSuccess: Bool

    private nonisolated static let bundledExecutableSubdirectory = "BundledResources/Bin"
    private nonisolated static let bundledModelSubdirectory = "BundledResources/Models"
    private nonisolated static let bundledExecutableName = "whisper-cli"
    private nonisolated static let bundledModelResourceName = "ggml-base"
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

        // Task 6 will replace this stub with a real JSON parse + map.
        Self.logger.info(
            "whisper-cli completed jsonSidecar=\(jsonURL.path, privacy: .public), stdoutLength=\(result.stdout.count, privacy: .public)"
        )
        return TranscriptionResult(
            text: result.stdout.trimmingCharacters(in: .whitespacesAndNewlines),
            segments: [],
            language: nil,
            duration: nil
        )
    }

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
            withExtension: nil,
            subdirectory: bundledExecutableSubdirectory
        ) {
            return url
        }
        logger.error("Could not find bundled whisper-cli at \(bundledExecutableSubdirectory, privacy: .public)/\(bundledExecutableName, privacy: .public)")
        throw WhisperEngineError.missingExecutable
    }

    private nonisolated static func resolveBundledModel() throws -> URL {
        if let url = Bundle.main.url(
            forResource: bundledModelResourceName,
            withExtension: bundledModelResourceExtension,
            subdirectory: bundledModelSubdirectory
        ) {
            return url
        }
        logger.error("Could not find bundled \(bundledModelResourceName, privacy: .public).\(bundledModelResourceExtension, privacy: .public) at \(bundledModelSubdirectory, privacy: .public)")
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
