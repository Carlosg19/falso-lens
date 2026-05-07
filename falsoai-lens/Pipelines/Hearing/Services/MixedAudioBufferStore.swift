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
    private let configuration: MixedAudioBufferConfiguration
    private let logger: Logger
    private var computerSamples: [Float] = []
    private var microphoneSamples: [Float] = []
    private var absoluteStartFrame: Int64 = 0
    private var nextChunkSequenceNumber = 0

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
        let availableFrames = max(computerSamples.count, microphoneSamples.count)
        return Double(availableFrames) / configuration.sampleRate
    }

    func append(_ packet: CapturedAudioPacket) throws -> [BufferedAudioChunk] {
        let monoSamples = try Self.normalizedMonoSamples(
            from: packet.buffer,
            source: packet.source,
            targetSampleRate: configuration.sampleRate
        )

        switch packet.source {
        case .computer:
            computerSamples.append(contentsOf: monoSamples)
        case .microphone:
            microphoneSamples.append(contentsOf: monoSamples)
        }

        return try drainAvailableChunks()
    }

    func drainAvailableChunks() throws -> [BufferedAudioChunk] {
        var chunks: [BufferedAudioChunk] = []

        while let chunk = try nextChunk() {
            chunks.append(chunk)
        }

        return chunks
    }

    func clear() {
        computerSamples.removeAll(keepingCapacity: false)
        microphoneSamples.removeAll(keepingCapacity: false)
        absoluteStartFrame = 0
        nextChunkSequenceNumber = 0
    }

    private func nextChunk() throws -> BufferedAudioChunk? {
        let chunkFrameCount = max(1, Int((configuration.chunkDuration * configuration.sampleRate).rounded(.toNearestOrAwayFromZero)))
        let overlapFrameCount = Int((configuration.overlapDuration * configuration.sampleRate).rounded(.toNearestOrAwayFromZero))
        guard overlapFrameCount < chunkFrameCount else {
            throw MixedAudioBufferStoreError.invalidConfiguration(
                sampleRate: configuration.sampleRate,
                chunkDuration: configuration.chunkDuration,
                overlapDuration: configuration.overlapDuration
            )
        }

        let availableFrames = max(computerSamples.count, microphoneSamples.count)
        guard availableFrames >= chunkFrameCount else {
            return nil
        }

        let mixedSamples = Self.mixMonoSamples(
            computerSamples: computerSamples,
            microphoneSamples: microphoneSamples,
            frameCount: chunkFrameCount
        )

        let chunk = BufferedAudioChunk(
            sequenceNumber: nextChunkSequenceNumber,
            startFrame: absoluteStartFrame,
            samples: mixedSamples,
            sampleRate: configuration.sampleRate,
            channelCount: 1,
            frameCount: chunkFrameCount
        )

        let framesToRemove = chunkFrameCount - overlapFrameCount
        removeFirstFrames(framesToRemove)
        absoluteStartFrame += Int64(framesToRemove)
        nextChunkSequenceNumber += 1

        logger.info(
            "Mixed chunk emitted sequence=\(chunk.sequenceNumber, privacy: .public), frames=\(chunk.frameCount, privacy: .public), remainingComputerFrames=\(self.computerSamples.count, privacy: .public), remainingMicFrames=\(self.microphoneSamples.count, privacy: .public)"
        )

        return chunk
    }

    private func removeFirstFrames(_ frameCount: Int) {
        if computerSamples.count <= frameCount {
            computerSamples.removeAll(keepingCapacity: true)
        } else {
            computerSamples.removeFirst(frameCount)
        }

        if microphoneSamples.count <= frameCount {
            microphoneSamples.removeAll(keepingCapacity: true)
        } else {
            microphoneSamples.removeFirst(frameCount)
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

    private nonisolated static func mixMonoSamples(
        computerSamples: [Float],
        microphoneSamples: [Float],
        frameCount: Int
    ) -> [Float] {
        var mixedSamples: [Float] = []
        mixedSamples.reserveCapacity(frameCount)

        for frameIndex in 0..<frameCount {
            var total: Float = 0
            var activeSourceCount: Float = 0

            if frameIndex < computerSamples.count {
                total += computerSamples[frameIndex]
                activeSourceCount += 1
            }

            if frameIndex < microphoneSamples.count {
                total += microphoneSamples[frameIndex]
                activeSourceCount += 1
            }

            let mixedSample = activeSourceCount > 0 ? total / activeSourceCount : 0
            mixedSamples.append(min(max(mixedSample, -1), 1))
        }

        return mixedSamples
    }

    #if DEBUG
    nonisolated static func runMixerSmokeCheck() {
        let mixed = mixMonoSamples(
            computerSamples: [0.2, 0.4, 0.6],
            microphoneSamples: [0.6, 0.4],
            frameCount: 3
        )

        assert(mixed == [0.4, 0.4, 0.6], "Mixer smoke check produced \(mixed)")
    }
    #endif
}
