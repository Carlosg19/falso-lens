import Combine
import Foundation

struct AudioTranscriptCacheDisplayRow: Identifiable, Equatable {
    let id: String
    let source: CapturedAudioSource
    let capturedAt: Date
    let sessionID: UUID
    let chunkID: String
    let sequenceNumber: Int
    let startTime: TimeInterval
    let endTime: TimeInterval
    let duration: TimeInterval
    let language: String?
    let text: String
    let inferenceDurationSeconds: Double?

    init(record: ComputerAudioCacheRecord) {
        self.id = "computer-\(record.sessionID.uuidString)-\(record.chunkID)-\(record.id ?? -1)"
        self.source = .computer
        self.capturedAt = record.capturedAt
        self.sessionID = record.sessionID
        self.chunkID = record.chunkID
        self.sequenceNumber = record.sequenceNumber
        self.startTime = record.startTime
        self.endTime = record.endTime
        self.duration = record.duration
        self.language = record.language
        self.text = record.text
        self.inferenceDurationSeconds = record.inferenceDurationSeconds
    }

    init(record: MicrophoneAudioCacheRecord) {
        self.id = "microphone-\(record.sessionID.uuidString)-\(record.chunkID)-\(record.id ?? -1)"
        self.source = .microphone
        self.capturedAt = record.capturedAt
        self.sessionID = record.sessionID
        self.chunkID = record.chunkID
        self.sequenceNumber = record.sequenceNumber
        self.startTime = record.startTime
        self.endTime = record.endTime
        self.duration = record.duration
        self.language = record.language
        self.text = record.text
        self.inferenceDurationSeconds = record.inferenceDurationSeconds
    }
}

@MainActor
final class AudioTranscriptCacheBrowserViewModel: ObservableObject {
    @Published private(set) var computerRows: [AudioTranscriptCacheDisplayRow] = []
    @Published private(set) var microphoneRows: [AudioTranscriptCacheDisplayRow] = []
    @Published private(set) var isRefreshing = false
    @Published private(set) var errorMessage: String?

    private let cache: AudioTranscriptCache?

    init(cache: AudioTranscriptCache? = try? AudioTranscriptCache.makeDefault()) {
        self.cache = cache
        if cache == nil {
            errorMessage = "Audio transcript cache is unavailable."
        }
    }

    var hasRows: Bool {
        !computerRows.isEmpty || !microphoneRows.isEmpty
    }

    var totalRows: Int {
        computerRows.count + microphoneRows.count
    }

    func refresh(limit: Int = 50) async {
        guard let cache else {
            errorMessage = "Audio transcript cache is unavailable."
            return
        }

        isRefreshing = true
        defer { isRefreshing = false }

        do {
            let computerRecords = try await cache.fetchRecentComputerChunks(limit: limit)
            let microphoneRecords = try await cache.fetchRecentMicrophoneChunks(limit: limit)

            computerRows = computerRecords.map(AudioTranscriptCacheDisplayRow.init(record:))
            microphoneRows = microphoneRecords.map(AudioTranscriptCacheDisplayRow.init(record:))
            errorMessage = nil
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}
