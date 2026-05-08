import Foundation
import OSLog

enum MixedAudioBufferStoreError: LocalizedError, Equatable {
    case invalidConfiguration(sampleRate: Double, chunkDuration: TimeInterval, overlapDuration: TimeInterval)
    case invalidSampleLayout(source: CapturedAudioSource, expectedSamples: Int, actualSamples: Int)

    var errorDescription: String? {
        switch self {
        case let .invalidConfiguration(sampleRate, chunkDuration, overlapDuration):
            return "Mixed audio configuration is invalid. Sample rate \(sampleRate) Hz, chunk duration \(chunkDuration)s, and overlap \(overlapDuration)s must describe a positive chunk with less overlap than duration."
        case let .invalidSampleLayout(source, expectedSamples, actualSamples):
            return "\(source.rawValue.capitalized) audio sample layout is invalid. Expected \(expectedSamples) samples, got \(actualSamples)."
        }
    }
}

struct MixedAudioBufferConfiguration: Sendable, Equatable {
    var sampleRate: Double
    var chunkDuration: TimeInterval
    var overlapDuration: TimeInterval

    nonisolated static let liveTranscription = MixedAudioBufferConfiguration(
        sampleRate: 48_000,
        chunkDuration: AudioChunkingConfiguration.mvp.chunkDuration,
        overlapDuration: AudioChunkingConfiguration.mvp.overlapDuration
    )

    nonisolated func validate() throws {
        guard sampleRate > 0, chunkDuration > 0, overlapDuration >= 0, overlapDuration < chunkDuration else {
            throw MixedAudioBufferStoreError.invalidConfiguration(
                sampleRate: sampleRate,
                chunkDuration: chunkDuration,
                overlapDuration: overlapDuration
            )
        }
    }
}

actor MixedAudioBufferStore {
    private struct SourceBufferState {
        var samples: [Float] = []
        var absoluteStartFrame: Int64 = 0
        var nextChunkSequenceNumber = 0
    }

    private let configuration: MixedAudioBufferConfiguration
    private let logger: Logger
    private var computerState = SourceBufferState()
    private var microphoneState = SourceBufferState()

    init(
        configuration: MixedAudioBufferConfiguration = .liveTranscription,
        logger: Logger = Logger(
            subsystem: Bundle.main.bundleIdentifier ?? "com.falsoai.FalsoaiLens",
            category: "MixedAudioBuffer"
        )
    ) throws {
        try configuration.validate()
        self.configuration = configuration
        self.logger = logger
    }

    var availableDuration: TimeInterval {
        let availableFrames = max(computerState.samples.count, microphoneState.samples.count)
        return Double(availableFrames) / configuration.sampleRate
    }

    func append(_ packet: CapturedAudioPacket) throws -> [SeparatedAudioChunkBatch] {
        let monoSamples = try Self.normalizedMonoSamples(
            from: packet.buffer,
            source: packet.source,
            targetSampleRate: configuration.sampleRate
        )

        switch packet.source {
        case .computer:
            computerState.samples.append(contentsOf: monoSamples)
        case .microphone:
            microphoneState.samples.append(contentsOf: monoSamples)
        }

        return try drainAvailableChunks()
    }

    func drainAvailableChunks() throws -> [SeparatedAudioChunkBatch] {
        var batches: [SeparatedAudioChunkBatch] = []

        while true {
            let microphoneReady = hasChunkReady(in: microphoneState)
            let computerReady = hasChunkReady(in: computerState)

            if !microphoneReady, !computerReady {
                break
            }

            if !microphoneReady, computerReady, !microphoneState.samples.isEmpty {
                break
            }

            let nextSequenceNumber = min(
                microphoneReady ? microphoneState.nextChunkSequenceNumber : Int.max,
                computerReady ? computerState.nextChunkSequenceNumber : Int.max
            )

            let microphoneChunk = microphoneReady && microphoneState.nextChunkSequenceNumber == nextSequenceNumber
                ? try nextChunk(for: .microphone)
                : nil
            let computerChunk = computerReady && computerState.nextChunkSequenceNumber == nextSequenceNumber
                ? try nextChunk(for: .computer)
                : nil

            let batch = SeparatedAudioChunkBatch(
                sequenceNumber: nextSequenceNumber,
                microphone: microphoneChunk,
                computer: computerChunk
            )

            if batch.isEmpty {
                break
            }

            batches.append(batch)
        }

        return batches
    }

    func clear() {
        computerState = SourceBufferState()
        microphoneState = SourceBufferState()
    }

    private func nextChunk(for source: CapturedAudioSource) throws -> BufferedAudioChunk? {
        let chunk: BufferedAudioChunk?
        switch source {
        case .computer:
            chunk = try nextChunk(source: source, state: &computerState)
        case .microphone:
            chunk = try nextChunk(source: source, state: &microphoneState)
        }

        if let chunk {
            logger.info(
                "Separated chunk emitted source=\(source.rawValue, privacy: .public), sequence=\(chunk.sequenceNumber, privacy: .public), frames=\(chunk.frameCount, privacy: .public), remainingComputerFrames=\(self.computerState.samples.count, privacy: .public), remainingMicFrames=\(self.microphoneState.samples.count, privacy: .public)"
            )
        }

        return chunk
    }

    private func nextChunk(
        source: CapturedAudioSource,
        state: inout SourceBufferState
    ) throws -> BufferedAudioChunk? {
        let chunkFrameCount = self.chunkFrameCount
        let overlapFrameCount = Int((configuration.overlapDuration * configuration.sampleRate).rounded(.toNearestOrAwayFromZero))
        guard overlapFrameCount < chunkFrameCount else {
            throw MixedAudioBufferStoreError.invalidConfiguration(
                sampleRate: configuration.sampleRate,
                chunkDuration: configuration.chunkDuration,
                overlapDuration: configuration.overlapDuration
            )
        }

        guard state.samples.count >= chunkFrameCount else {
            return nil
        }

        let chunkSamples = Array(state.samples.prefix(chunkFrameCount))

        let chunk = BufferedAudioChunk(
            source: source,
            sequenceNumber: state.nextChunkSequenceNumber,
            startFrame: state.absoluteStartFrame,
            samples: chunkSamples,
            sampleRate: configuration.sampleRate,
            channelCount: 1,
            frameCount: chunkFrameCount
        )

        let framesToRemove = chunkFrameCount - overlapFrameCount
        removeFirstFrames(framesToRemove, from: &state)
        state.absoluteStartFrame += Int64(framesToRemove)
        state.nextChunkSequenceNumber += 1

        return chunk
    }

    private var chunkFrameCount: Int {
        max(1, Int((configuration.chunkDuration * configuration.sampleRate).rounded(.toNearestOrAwayFromZero)))
    }

    private func hasChunkReady(in state: SourceBufferState) -> Bool {
        state.samples.count >= chunkFrameCount
    }

    private func removeFirstFrames(_ frameCount: Int, from state: inout SourceBufferState) {
        if state.samples.count <= frameCount {
            state.samples.removeAll(keepingCapacity: true)
        } else {
            state.samples.removeFirst(frameCount)
        }
    }

    private nonisolated static func normalizedMonoSamples(
        from buffer: CapturedAudioBuffer,
        source: CapturedAudioSource,
        targetSampleRate: Double
    ) throws -> [Float] {
        guard buffer.frameCount > 0 else { return [] }
        guard buffer.channelCount > 0 else {
            throw MixedAudioBufferStoreError.invalidSampleLayout(
                source: source,
                expectedSamples: 0,
                actualSamples: buffer.samples.count
            )
        }

        let expectedSamples = buffer.frameCount * buffer.channelCount
        guard buffer.samples.count == expectedSamples else {
            throw MixedAudioBufferStoreError.invalidSampleLayout(
                source: source,
                expectedSamples: expectedSamples,
                actualSamples: buffer.samples.count
            )
        }

        let monoSamples: [Float]
        if buffer.channelCount == 1 {
            monoSamples = buffer.samples
        } else {
            var downmixedSamples: [Float] = []
            downmixedSamples.reserveCapacity(buffer.frameCount)

            for frameIndex in 0..<buffer.frameCount {
                let frameStartIndex = frameIndex * buffer.channelCount
                var total: Float = 0

                for channelIndex in 0..<buffer.channelCount {
                    total += buffer.samples[frameStartIndex + channelIndex]
                }

                downmixedSamples.append(total / Float(buffer.channelCount))
            }
            monoSamples = downmixedSamples
        }

        return resampleMono(
            monoSamples,
            sourceSampleRate: buffer.sampleRate,
            targetSampleRate: targetSampleRate
        )
    }

    private nonisolated static func resampleMono(
        _ samples: [Float],
        sourceSampleRate: Double,
        targetSampleRate: Double
    ) -> [Float] {
        guard !samples.isEmpty, sourceSampleRate > 0, targetSampleRate > 0 else {
            return []
        }

        guard sourceSampleRate != targetSampleRate else {
            return samples
        }

        let sampleRateRatio = targetSampleRate / sourceSampleRate
        let outputSampleCount = max(
            1,
            Int((Double(samples.count) * sampleRateRatio).rounded(.toNearestOrAwayFromZero))
        )

        var outputSamples: [Float] = []
        outputSamples.reserveCapacity(outputSampleCount)

        for outputIndex in 0..<outputSampleCount {
            let sourcePosition = Double(outputIndex) / sampleRateRatio
            let lowerIndex = min(Int(sourcePosition.rounded(.down)), samples.count - 1)
            let upperIndex = min(lowerIndex + 1, samples.count - 1)
            let interpolationAmount = Float(sourcePosition - Double(lowerIndex))
            let lowerSample = samples[lowerIndex]
            let upperSample = samples[upperIndex]

            outputSamples.append(
                lowerSample + ((upperSample - lowerSample) * interpolationAmount)
            )
        }

        return outputSamples
    }

    #if DEBUG
    nonisolated static func runSeparatedSourceSmokeCheck() {
        let computerChunk = BufferedAudioChunk(
            source: .computer,
            sequenceNumber: 0,
            startFrame: 0,
            samples: [0.2, 0.4, 0.6],
            sampleRate: 48_000,
            channelCount: 1,
            frameCount: 3
        )
        assert(
            computerChunk.source == .computer && computerChunk.samples == [0.2, 0.4, 0.6],
            "Computer chunks must preserve source identity and samples"
        )

        let microphoneChunk = BufferedAudioChunk(
            source: .microphone,
            sequenceNumber: 0,
            startFrame: 0,
            samples: [0.6, 0.4],
            sampleRate: 48_000,
            channelCount: 1,
            frameCount: 2
        )
        assert(
            microphoneChunk.source == .microphone && microphoneChunk.samples == [0.6, 0.4],
            "Microphone chunks must preserve source identity and samples"
        )
    }
    #endif
}
