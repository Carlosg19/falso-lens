import Foundation
import OSLog

enum WhisperOutputParser {
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.falsoai.FalsoaiLens",
        category: "WhisperParser"
    )

    static func decodeTranscriptionResult(from data: Data) throws -> TranscriptionResult {
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

    static func parseWhisperTimestamp(_ raw: String) -> TimeInterval? {
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
    static func runParserSmokeCheck() {
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
}
