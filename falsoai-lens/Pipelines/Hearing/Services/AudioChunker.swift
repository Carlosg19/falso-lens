import Foundation

actor AudioChunker {
    private let bufferStore: AudioBufferStore
    private let configuration: AudioChunkingConfiguration

    init(
        bufferStore: AudioBufferStore = AudioBufferStore(),
        configuration: AudioChunkingConfiguration = .mvp
    ) throws {
        try configuration.validate()
        self.bufferStore = bufferStore
        self.configuration = configuration
    }

    func append(_ buffer: CapturedAudioBuffer) async throws -> [BufferedAudioChunk] {
        try await bufferStore.append(buffer)
        return try await drainAvailableChunks()
    }

    func drainAvailableChunks() async throws -> [BufferedAudioChunk] {
        var chunks: [BufferedAudioChunk] = []

        while let chunk = try await nextChunk() {
            chunks.append(chunk)
        }

        return chunks
    }

    func nextChunk() async throws -> BufferedAudioChunk? {
        try await bufferStore.extractChunk(
            duration: configuration.chunkDuration,
            retainingOverlap: configuration.overlapDuration
        )
    }

    func availableDuration() async -> TimeInterval {
        await bufferStore.availableDuration
    }

    func clear() async {
        await bufferStore.clear()
    }
}
