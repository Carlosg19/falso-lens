import Foundation

enum TranscriptCaptureMethod: String, Sendable, Equatable, Codable {
    case screenCaptureKit = "screen_capture_kit"
    case avAudioEngine = "av_audio_engine"
}

struct TranscriptSource: Sendable, Equatable, Codable {
    let source: CapturedAudioSource
    let captureMethod: TranscriptCaptureMethod
    let inputDevice: String?

    nonisolated init(
        source: CapturedAudioSource,
        captureMethod: TranscriptCaptureMethod,
        inputDevice: String? = nil
    ) {
        self.source = source
        self.captureMethod = captureMethod
        self.inputDevice = inputDevice
    }

    enum CodingKeys: String, CodingKey {
        case source
        case captureMethod = "capture_method"
        case inputDevice = "input_device"
    }
}

struct SourceTranscriptSegment: Sendable, Equatable, Codable {
    let startTime: TimeInterval
    let endTime: TimeInterval
    let text: String

    nonisolated init(
        startTime: TimeInterval,
        endTime: TimeInterval,
        text: String
    ) {
        self.startTime = startTime
        self.endTime = endTime
        self.text = text
    }

    enum CodingKeys: String, CodingKey {
        case startTime = "start_time"
        case endTime = "end_time"
        case text
    }
}

struct SourceTranscriptChunk: Sendable, Equatable, Identifiable, Codable {
    let chunkID: String
    let source: CapturedAudioSource
    let sequenceNumber: Int
    let startTime: TimeInterval
    let endTime: TimeInterval
    let duration: TimeInterval
    let language: String?
    let text: String
    let segments: [SourceTranscriptSegment]

    nonisolated var id: String { chunkID }

    nonisolated init(
        chunkID: String,
        source: CapturedAudioSource,
        sequenceNumber: Int,
        startTime: TimeInterval,
        endTime: TimeInterval,
        duration: TimeInterval,
        language: String?,
        text: String,
        segments: [SourceTranscriptSegment]
    ) {
        self.chunkID = chunkID
        self.source = source
        self.sequenceNumber = sequenceNumber
        self.startTime = startTime
        self.endTime = endTime
        self.duration = duration
        self.language = language
        self.text = text
        self.segments = segments
    }

    enum CodingKeys: String, CodingKey {
        case chunkID = "chunk_id"
        case source
        case sequenceNumber = "sequence_number"
        case startTime = "start_time"
        case endTime = "end_time"
        case duration
        case language
        case text
        case segments
    }
}

struct SourceSeparatedAudioTranscript: Sendable, Equatable, Codable {
    let schemaVersion: Int
    let language: String?
    let mode: String
    let timebase: String
    let sources: [TranscriptSource]
    let chunks: [SourceTranscriptChunk]

    nonisolated init(
        schemaVersion: Int = 1,
        language: String?,
        mode: TranscriptionMode,
        sources: [TranscriptSource],
        chunks: [SourceTranscriptChunk]
    ) {
        self.schemaVersion = schemaVersion
        self.language = language
        self.mode = mode.transcriptValue
        self.timebase = "seconds_since_capture_start"
        self.sources = sources
        self.chunks = chunks.sorted { lhs, rhs in
            if lhs.startTime != rhs.startTime {
                return lhs.startTime < rhs.startTime
            }
            if lhs.source.rawValue != rhs.source.rawValue {
                return lhs.source.rawValue < rhs.source.rawValue
            }
            return lhs.sequenceNumber < rhs.sequenceNumber
        }
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case language
        case mode
        case timebase
        case sources
        case chunks
    }
}
