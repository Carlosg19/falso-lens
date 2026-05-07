import Foundation

enum AudioBufferStoreError: LocalizedError, Equatable {
    case invalidSampleLayout(expectedSamples: Int, actualSamples: Int)
    case incompatibleFormat(
        expectedSampleRate: Double,
        actualSampleRate: Double,
        expectedChannelCount: Int,
        actualChannelCount: Int
    )
    case invalidExtractionRequest(duration: TimeInterval, overlap: TimeInterval)

    var errorDescription: String? {
        switch self {
        case let .invalidSampleLayout(expectedSamples, actualSamples):
            return "Captured audio buffer sample layout is invalid. Expected \(expectedSamples) samples, got \(actualSamples)."
        case let .incompatibleFormat(expectedSampleRate, actualSampleRate, expectedChannelCount, actualChannelCount):
            return "Captured audio format changed from \(expectedSampleRate) Hz / \(expectedChannelCount) channels to \(actualSampleRate) Hz / \(actualChannelCount) channels."
        case let .invalidExtractionRequest(duration, overlap):
            return "Audio chunk extraction request is invalid. Duration \(duration)s must be greater than overlap \(overlap)s."
        }
    }
}

actor AudioBufferStore {
    private var samples: [Float] = []
    private var sampleRate: Double?
    private var channelCount: Int?
    private var absoluteStartFrame: Int64 = 0
    private var nextChunkSequenceNumber = 0

    var availableFrameCount: Int {
        guard let channelCount, channelCount > 0 else { return 0 }
        return samples.count / channelCount
    }

    var availableDuration: TimeInterval {
        guard let sampleRate, sampleRate > 0 else { return 0 }
        return Double(availableFrameCount) / sampleRate
    }

    func append(_ buffer: CapturedAudioBuffer) throws {
        guard buffer.frameCount > 0 else { return }
        guard buffer.channelCount > 0 else {
            throw AudioBufferStoreError.invalidSampleLayout(
                expectedSamples: 0,
                actualSamples: buffer.samples.count
            )
        }

        let expectedSamples = buffer.frameCount * buffer.channelCount
        guard buffer.samples.count == expectedSamples else {
            throw AudioBufferStoreError.invalidSampleLayout(
                expectedSamples: expectedSamples,
                actualSamples: buffer.samples.count
            )
        }

        try validateFormat(sampleRate: buffer.sampleRate, channelCount: buffer.channelCount)
        samples.append(contentsOf: buffer.samples)
    }

    func extractChunk(
        duration: TimeInterval,
        retainingOverlap overlap: TimeInterval
    ) throws -> BufferedAudioChunk? {
        guard duration > 0, overlap >= 0, overlap < duration else {
            throw AudioBufferStoreError.invalidExtractionRequest(
                duration: duration,
                overlap: overlap
            )
        }

        guard let sampleRate, let channelCount, channelCount > 0 else {
            return nil
        }

        let chunkFrameCount = max(1, Int((duration * sampleRate).rounded(.toNearestOrAwayFromZero)))
        let overlapFrameCount = Int((overlap * sampleRate).rounded(.toNearestOrAwayFromZero))
        guard overlapFrameCount < chunkFrameCount else {
            throw AudioBufferStoreError.invalidExtractionRequest(
                duration: duration,
                overlap: overlap
            )
        }

        guard availableFrameCount >= chunkFrameCount else {
            return nil
        }

        let chunkSampleCount = chunkFrameCount * channelCount
        let chunkSamples = Array(samples.prefix(chunkSampleCount))
        let chunk = BufferedAudioChunk(
            sequenceNumber: nextChunkSequenceNumber,
            startFrame: absoluteStartFrame,
            samples: chunkSamples,
            sampleRate: sampleRate,
            channelCount: channelCount,
            frameCount: chunkFrameCount
        )

        let framesToRemove = chunkFrameCount - overlapFrameCount
        let samplesToRemove = framesToRemove * channelCount
        samples.removeFirst(samplesToRemove)
        absoluteStartFrame += Int64(framesToRemove)
        nextChunkSequenceNumber += 1

        return chunk
    }

    func clear() {
        samples.removeAll(keepingCapacity: false)
        sampleRate = nil
        channelCount = nil
        absoluteStartFrame = 0
        nextChunkSequenceNumber = 0
    }

    private func validateFormat(sampleRate newSampleRate: Double, channelCount newChannelCount: Int) throws {
        guard let existingSampleRate = sampleRate, let existingChannelCount = channelCount else {
            sampleRate = newSampleRate
            channelCount = newChannelCount
            return
        }

        guard existingSampleRate == newSampleRate, existingChannelCount == newChannelCount else {
            throw AudioBufferStoreError.incompatibleFormat(
                expectedSampleRate: existingSampleRate,
                actualSampleRate: newSampleRate,
                expectedChannelCount: existingChannelCount,
                actualChannelCount: newChannelCount
            )
        }
    }
}
