import Foundation

enum WhisperEngineError: LocalizedError, Equatable {
    case missingExecutable
    case missingModel
    case audioFileNotFound(URL)
    case audioFileEmpty(URL)
    case processFailed(exitCode: Int32, stderr: String)
    case invalidJSONOutput(String)

    var errorDescription: String? {
        switch self {
        case .missingExecutable:
            return "Bundled whisper-cli binary was not found inside the app."
        case .missingModel:
            return "Bundled Whisper model (ggml-small.bin) was not found inside the app."
        case let .audioFileNotFound(url):
            return "Audio file does not exist at \(url.path)."
        case let .audioFileEmpty(url):
            return "Audio file at \(url.path) is empty (0 bytes)."
        case let .processFailed(exitCode, stderr):
            let trimmed = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            let snippet = trimmed.count > 240 ? String(trimmed.prefix(240)) + "…" : trimmed
            return "whisper-cli exited with status \(exitCode). stderr: \(snippet.isEmpty ? "(empty)" : snippet)"
        case let .invalidJSONOutput(snippet):
            return "whisper-cli produced JSON output that could not be decoded. Excerpt: \(snippet)"
        }
    }

    var recoverySuggestion: String? {
        switch self {
        case .missingExecutable:
            return "Run `bash scripts/build-whisper-cli.sh` and rebuild the app."
        case .missingModel:
            return "Download `ggml-small.bin` (run `.build/whisper.cpp/models/download-ggml-model.sh small`) and place it at `BundledResources/Models/ggml-small.bin`, then rebuild the app."
        case .audioFileNotFound:
            return "Pick a WAV file that exists, or check that the audio capture pipeline produced a file."
        case .audioFileEmpty:
            return "The audio file has no content. Capture audio of at least 1 second before transcribing."
        case .processFailed:
            return "Check Console for the WhisperEngine category log for full stderr. If the error mentions an incompatible model, rebuild the binary or model."
        case .invalidJSONOutput:
            return "whisper.cpp may have changed its JSON schema. Pin the version in `scripts/build-whisper-cli.sh` and rebuild."
        }
    }
}
