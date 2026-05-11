import Combine
import Foundation
import OSLog

@MainActor
final class TranscriptDuplicateAnalyzer: ObservableObject {
    @Published private(set) var annotations: [DuplicateAnnotation] = []

    private struct WindowEntry {
        let chunk: SourceTranscriptChunk
        let samples: [Float]
        let sampleRate: Double
    }

    private struct DuplicateScore: Sendable {
        let confidence: Double
        let signals: [String]
    }

    private static let confidenceThreshold = 0.50
    private static let timeGateSeconds = 0.5
    private static let maxWindowEntries = 20
    private static let maxWindowSeconds: TimeInterval = 30

    private var windows: [CapturedAudioSource: [WindowEntry]] = [
        .computer: [],
        .microphone: []
    ]
    private var seenPairs: Set<String> = []
    private let logger: Logger

    init(
        logger: Logger = Logger(
            subsystem: Bundle.main.bundleIdentifier ?? "com.falsoai.FalsoaiLens",
            category: "TranscriptDuplicateAnalyzer"
        )
    ) {
        self.logger = logger
    }

    func ingest(_ event: LiveTranscriptChunkEvent) {
        let entry = WindowEntry(
            chunk: event.chunk,
            samples: event.normalizedSamples,
            sampleRate: event.normalizedSampleRate
        )

        var sourceWindow = windows[event.chunk.source] ?? []
        sourceWindow.append(entry)
        sourceWindow = Self.trimWindow(sourceWindow, referenceTime: event.chunk.endTime)
        windows[event.chunk.source] = sourceWindow

        let otherSource: CapturedAudioSource = event.chunk.source == .computer ? .microphone : .computer
        let candidates = windows[otherSource] ?? []

        guard !candidates.isEmpty else { return }

        Task.detached(priority: .utility) { [weak self, entry, candidates] in
            let scoredPairs = Self.scoreCandidates(new: entry, candidates: candidates)

            await MainActor.run {
                self?.applyScoredPairs(newEntry: entry, scoredPairs: scoredPairs)
            }
        }
    }

    func reset() {
        windows = [.computer: [], .microphone: []]
        seenPairs.removeAll()
        annotations.removeAll()
    }

    private func applyScoredPairs(
        newEntry: WindowEntry,
        scoredPairs: [(SourceTranscriptChunk, DuplicateScore)]
    ) {
        for (candidateChunk, score) in scoredPairs {
            let pairKey = Self.pairKey(newEntry.chunk.chunkID, candidateChunk.chunkID)
            guard !seenPairs.contains(pairKey) else { continue }
            guard score.confidence >= Self.confidenceThreshold else { continue }

            let (primary, duplicate) = Self.orderPair(newEntry.chunk, candidateChunk)
            let annotation = DuplicateAnnotation(
                chunkID: duplicate.chunkID,
                duplicateOfChunkID: primary.chunkID,
                confidence: score.confidence,
                signals: score.signals
            )
            annotations.append(annotation)
            seenPairs.insert(pairKey)

            logger.info(
                "Duplicate annotated chunkID=\(annotation.chunkID, privacy: .public) duplicateOf=\(annotation.duplicateOfChunkID, privacy: .public) confidence=\(annotation.confidence, privacy: .public) signals=\(annotation.signals.joined(separator: ","), privacy: .public)"
            )
        }
    }

    private nonisolated static func trimWindow(
        _ window: [WindowEntry],
        referenceTime: TimeInterval
    ) -> [WindowEntry] {
        let cutoff = referenceTime - maxWindowSeconds
        var trimmed = window.filter { $0.chunk.endTime >= cutoff }
        if trimmed.count > maxWindowEntries {
            trimmed.removeFirst(trimmed.count - maxWindowEntries)
        }
        return trimmed
    }

    private nonisolated static func scoreCandidates(
        new: WindowEntry,
        candidates: [WindowEntry]
    ) -> [(SourceTranscriptChunk, DuplicateScore)] {
        candidates.compactMap { candidate in
            guard timeWindowOverlap(new.chunk, candidate.chunk) else { return nil }
            let score = scoreDuplicate(new: new, candidate: candidate)
            return (candidate.chunk, score)
        }
    }

    private nonisolated static func timeWindowOverlap(
        _ a: SourceTranscriptChunk,
        _ b: SourceTranscriptChunk
    ) -> Bool {
        let earliest = min(a.startTime, b.startTime)
        let latest = max(a.endTime, b.endTime)
        let unionDuration = latest - earliest
        let summedDuration = a.duration + b.duration
        if summedDuration > unionDuration { return true }
        return abs(a.startTime - b.startTime) < timeGateSeconds
    }

    private nonisolated static func scoreDuplicate(
        new: WindowEntry,
        candidate: WindowEntry
    ) -> DuplicateScore {
        var confidence = 0.0
        var signals: [String] = []

        let timeDelta = abs(new.chunk.startTime - candidate.chunk.startTime)
        if timeDelta < 0.300 {
            confidence += 0.10
            signals.append("time_overlap")
        }

        if candidate.chunk.duration > 0 {
            let durationRatio = new.chunk.duration / candidate.chunk.duration
            if durationRatio > 0.85, durationRatio < 1.15 {
                confidence += 0.05
                signals.append("duration_match")
            }
        }

        if let lhsLanguage = new.chunk.language,
           let rhsLanguage = candidate.chunk.language,
           lhsLanguage == rhsLanguage {
            confidence += 0.05
            signals.append("language_match")
        }

        if TranscriptSimilarityHelpers.isLikelySameUtterance(new.chunk.text, candidate.chunk.text) {
            confidence += 0.45
            signals.append("text_jaccard")
        }

        if !new.samples.isEmpty,
           !candidate.samples.isEmpty,
           new.sampleRate == candidate.sampleRate {
            let pcmCorr = TranscriptSimilarityHelpers.absoluteCorrelation(
                new.samples,
                candidate.samples
            )
            if pcmCorr >= 0.50 {
                confidence += 0.35
                signals.append("pcm_correlation")
            }
        }

        let newWordCount = TranscriptSimilarityHelpers.normalizedWords(new.chunk.text).count
        let candidateWordCount = TranscriptSimilarityHelpers.normalizedWords(candidate.chunk.text).count
        if newWordCount < 3 || candidateWordCount < 3 {
            confidence *= 0.3
            signals.append("filler_penalty")
        }

        return DuplicateScore(
            confidence: min(1.0, confidence),
            signals: signals
        )
    }

    private nonisolated static func orderPair(
        _ a: SourceTranscriptChunk,
        _ b: SourceTranscriptChunk
    ) -> (primary: SourceTranscriptChunk, duplicate: SourceTranscriptChunk) {
        if a.startTime != b.startTime {
            return a.startTime < b.startTime ? (a, b) : (b, a)
        }
        if a.source == .computer, b.source != .computer {
            return (a, b)
        }
        if b.source == .computer, a.source != .computer {
            return (b, a)
        }
        return a.chunkID <= b.chunkID ? (a, b) : (b, a)
    }

    private nonisolated static func pairKey(_ lhs: String, _ rhs: String) -> String {
        lhs <= rhs ? "\(lhs)|\(rhs)" : "\(rhs)|\(lhs)"
    }

    #if DEBUG
    nonisolated static func runDuplicateSmokeCheck() {
        let computerChunk = SourceTranscriptChunk(
            chunkID: "computer_001",
            source: .computer,
            sequenceNumber: 1,
            startTime: 5.0,
            endTime: 10.0,
            duration: 5.0,
            language: "en",
            text: "The deadline is tomorrow morning.",
            segments: []
        )
        let microphoneChunk = SourceTranscriptChunk(
            chunkID: "microphone_001",
            source: .microphone,
            sequenceNumber: 1,
            startTime: 5.05,
            endTime: 10.05,
            duration: 5.0,
            language: "en",
            text: "the deadline is tomorrow morning",
            segments: []
        )
        let computerEntry = WindowEntry(
            chunk: computerChunk,
            samples: [],
            sampleRate: 16_000
        )
        let microphoneEntry = WindowEntry(
            chunk: microphoneChunk,
            samples: [],
            sampleRate: 16_000
        )

        let pairs = scoreCandidates(new: microphoneEntry, candidates: [computerEntry])
        assert(pairs.count == 1, "Expected one scored pair for near-identical text")
        let (matchedChunk, score) = pairs[0]
        assert(matchedChunk.chunkID == "computer_001", "Expected match to be the computer chunk")
        assert(score.confidence >= confidenceThreshold, "Expected confidence above threshold for near-identical utterance")
        assert(score.signals.contains("text_jaccard"), "Expected text_jaccard signal to fire")

        let unrelatedChunk = SourceTranscriptChunk(
            chunkID: "computer_002",
            source: .computer,
            sequenceNumber: 2,
            startTime: 60.0,
            endTime: 65.0,
            duration: 5.0,
            language: "en",
            text: "Completely different topic about lunch.",
            segments: []
        )
        let unrelatedEntry = WindowEntry(
            chunk: unrelatedChunk,
            samples: [],
            sampleRate: 16_000
        )
        let unrelatedPairs = scoreCandidates(new: microphoneEntry, candidates: [unrelatedEntry])
        assert(unrelatedPairs.isEmpty, "Expected unrelated chunks outside the time gate to be filtered")

        let fillerChunkA = SourceTranscriptChunk(
            chunkID: "computer_003",
            source: .computer,
            sequenceNumber: 3,
            startTime: 5.0,
            endTime: 10.0,
            duration: 5.0,
            language: "en",
            text: "Thanks.",
            segments: []
        )
        let fillerChunkB = SourceTranscriptChunk(
            chunkID: "microphone_003",
            source: .microphone,
            sequenceNumber: 3,
            startTime: 5.05,
            endTime: 10.05,
            duration: 5.0,
            language: "en",
            text: "Thanks.",
            segments: []
        )
        let fillerA = WindowEntry(chunk: fillerChunkA, samples: [], sampleRate: 16_000)
        let fillerB = WindowEntry(chunk: fillerChunkB, samples: [], sampleRate: 16_000)
        let fillerPairs = scoreCandidates(new: fillerB, candidates: [fillerA])
        assert(fillerPairs.count == 1, "Expected filler pair to still produce a score entry")
        assert(fillerPairs[0].1.confidence < confidenceThreshold, "Expected filler-word penalty to drop confidence below threshold")
        assert(fillerPairs[0].1.signals.contains("filler_penalty"), "Expected filler_penalty signal to fire")

        let (primary, duplicate) = orderPair(microphoneChunk, computerChunk)
        assert(primary.chunkID == "computer_001", "Expected earlier-start computer chunk to be primary")
        assert(duplicate.chunkID == "microphone_001", "Expected later mic chunk to be the duplicate")
    }
    #endif
}
