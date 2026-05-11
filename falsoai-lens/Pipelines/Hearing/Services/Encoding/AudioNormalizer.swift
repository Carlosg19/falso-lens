import Foundation

actor AudioNormalizer {
    private let configuration: AudioNormalizationConfiguration
    private let wavWriter: WAVWriter

    init(
        configuration: AudioNormalizationConfiguration = .whisperMVP,
        wavWriter: WAVWriter? = nil
    ) throws {
        try configuration.validate()
        self.configuration = configuration
        self.wavWriter = wavWriter ?? WAVWriter(outputDirectory: configuration.outputDirectory)
    }

    func normalize(_ chunk: BufferedAudioChunk) throws -> NormalizedAudioChunk {
        let monoSamples = try Self.downmixToMono(chunk)
        let normalizedSamples = Self.resampleMono(
            monoSamples,
            sourceSampleRate: chunk.sampleRate,
            targetSampleRate: configuration.targetSampleRate
        )

        return NormalizedAudioChunk(
            source: chunk.source,
            sequenceNumber: chunk.sequenceNumber,
            startFrame: chunk.startFrame,
            samples: normalizedSamples,
            sampleRate: configuration.targetSampleRate,
            channelCount: configuration.targetChannelCount,
            sourceSampleRate: chunk.sampleRate,
            sourceChannelCount: chunk.channelCount,
            fileURL: nil
        )
    }

    func normalizeToTemporaryWAV(_ chunk: BufferedAudioChunk) async throws -> NormalizedAudioChunk {
        let normalizedChunk = try normalize(chunk)
        let fileURL = try await wavWriter.write(normalizedChunk)
        return normalizedChunk.withFileURL(fileURL)
    }

    private nonisolated static func downmixToMono(_ chunk: BufferedAudioChunk) throws -> [Float] {
        guard chunk.sampleRate > 0, chunk.channelCount > 0, chunk.frameCount > 0 else {
            throw AudioNormalizationError.invalidChunkFormat(
                sampleRate: chunk.sampleRate,
                channelCount: chunk.channelCount,
                frameCount: chunk.frameCount
            )
        }

        let expectedSamples = chunk.frameCount * chunk.channelCount
        guard chunk.samples.count == expectedSamples else {
            throw AudioNormalizationError.invalidChunkLayout(
                expectedSamples: expectedSamples,
                actualSamples: chunk.samples.count
            )
        }

        guard chunk.channelCount > 1 else {
            return chunk.samples
        }

        var monoSamples: [Float] = []
        monoSamples.reserveCapacity(chunk.frameCount)

        for frameIndex in 0..<chunk.frameCount {
            let frameStartIndex = frameIndex * chunk.channelCount
            var frameTotal: Float = 0

            for channelIndex in 0..<chunk.channelCount {
                frameTotal += chunk.samples[frameStartIndex + channelIndex]
            }

            monoSamples.append(frameTotal / Float(chunk.channelCount))
        }

        return monoSamples
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
}
