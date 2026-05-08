import Foundation

struct SeparatedAudioChunkBatch: Sendable, Equatable {
    let sequenceNumber: Int
    let microphone: BufferedAudioChunk?
    let computer: BufferedAudioChunk?

    var chunksInProcessingOrder: [BufferedAudioChunk] {
        [microphone, computer].compactMap { $0 }
    }

    var isEmpty: Bool {
        microphone == nil && computer == nil
    }
}
