import Foundation

actor WAVWriter {
    private let outputDirectory: URL

    init(outputDirectory: URL = AudioNormalizationConfiguration.whisperMVP.outputDirectory) {
        self.outputDirectory = outputDirectory
    }

    func write(_ chunk: NormalizedAudioChunk) throws -> URL {
        try FileManager.default.createDirectory(
            at: outputDirectory,
            withIntermediateDirectories: true
        )

        let fileURL = outputDirectory.appendingPathComponent(
            String(format: "chunk-%04d.wav", chunk.sequenceNumber)
        )
        let wavData = try Self.wavData(for: chunk)
        try wavData.write(to: fileURL, options: [.atomic])
        return fileURL
    }

    private nonisolated static func wavData(for chunk: NormalizedAudioChunk) throws -> Data {
        let bytesPerSample = 2
        let dataByteCount = chunk.samples.count * bytesPerSample
        guard dataByteCount <= Int(UInt32.max) else {
            throw AudioNormalizationError.wavDataTooLarge(sampleCount: chunk.samples.count)
        }

        let sampleRate = UInt32(chunk.sampleRate.rounded(.toNearestOrAwayFromZero))
        let channelCount = UInt16(chunk.channelCount)
        let bitsPerSample: UInt16 = 16
        let blockAlign = channelCount * bitsPerSample / 8
        let byteRate = sampleRate * UInt32(blockAlign)
        let dataSize = UInt32(dataByteCount)
        let riffSize = UInt32(36) + dataSize

        var data = Data()
        data.reserveCapacity(44 + dataByteCount)

        appendASCII("RIFF", to: &data)
        appendUInt32(riffSize, to: &data)
        appendASCII("WAVE", to: &data)
        appendASCII("fmt ", to: &data)
        appendUInt32(16, to: &data)
        appendUInt16(1, to: &data)
        appendUInt16(channelCount, to: &data)
        appendUInt32(sampleRate, to: &data)
        appendUInt32(byteRate, to: &data)
        appendUInt16(blockAlign, to: &data)
        appendUInt16(bitsPerSample, to: &data)
        appendASCII("data", to: &data)
        appendUInt32(dataSize, to: &data)

        for sample in chunk.samples {
            let clampedSample = min(max(sample, -1), 1)
            let scaledSample = clampedSample < 0
                ? clampedSample * 32_768
                : clampedSample * 32_767
            appendInt16(Int16(scaledSample.rounded()), to: &data)
        }

        return data
    }

    private nonisolated static func appendASCII(_ value: String, to data: inout Data) {
        data.append(contentsOf: value.utf8)
    }

    private nonisolated static func appendUInt16(_ value: UInt16, to data: inout Data) {
        var littleEndianValue = value.littleEndian
        withUnsafeBytes(of: &littleEndianValue) { buffer in
            data.append(contentsOf: buffer)
        }
    }

    private nonisolated static func appendUInt32(_ value: UInt32, to data: inout Data) {
        var littleEndianValue = value.littleEndian
        withUnsafeBytes(of: &littleEndianValue) { buffer in
            data.append(contentsOf: buffer)
        }
    }

    private nonisolated static func appendInt16(_ value: Int16, to data: inout Data) {
        var littleEndianValue = value.littleEndian
        withUnsafeBytes(of: &littleEndianValue) { buffer in
            data.append(contentsOf: buffer)
        }
    }
}
