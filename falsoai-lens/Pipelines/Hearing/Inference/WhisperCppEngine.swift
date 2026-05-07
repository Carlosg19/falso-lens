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
        // Implementation lands in Task 5 (Process invocation) and Task 6 (JSON parsing).
        // Stub for now so the type compiles.
        _ = audioFile
        _ = mode
        throw WhisperEngineError.processFailed(exitCode: -1, stderr: "transcribe not yet implemented")
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
