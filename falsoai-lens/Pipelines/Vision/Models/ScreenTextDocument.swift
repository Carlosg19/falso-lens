import CoreGraphics
import Foundation

struct ScreenTextDocument: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    let capturedAt: Date
    let frameSize: CGSize
    let frameHash: String
    let normalizedTextHash: String
    let layoutHash: String
    let observations: [ScreenTextObservation]
    let lines: [ScreenTextLine]
    let blocks: [ScreenTextBlock]
    let regions: [ScreenTextRegion]

    var recognizedText: String {
        if !blocks.isEmpty {
            return blocks.map(\.text).joined(separator: "\n\n")
        }

        if !lines.isEmpty {
            return lines.map(\.text).joined(separator: "\n")
        }

        return observations.map(\.text).joined(separator: "\n")
    }

    nonisolated init(
        id: UUID = UUID(),
        capturedAt: Date,
        frameSize: CGSize,
        frameHash: String,
        normalizedTextHash: String,
        layoutHash: String,
        observations: [ScreenTextObservation],
        lines: [ScreenTextLine],
        blocks: [ScreenTextBlock],
        regions: [ScreenTextRegion]
    ) {
        self.id = id
        self.capturedAt = capturedAt
        self.frameSize = frameSize
        self.frameHash = frameHash
        self.normalizedTextHash = normalizedTextHash
        self.layoutHash = layoutHash
        self.observations = observations
        self.lines = lines
        self.blocks = blocks
        self.regions = regions
    }
}

struct ScreenTextObservation: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    let text: String
    let boundingBox: CGRect
    let confidence: Float

    nonisolated init(
        id: UUID = UUID(),
        text: String,
        boundingBox: CGRect,
        confidence: Float
    ) {
        self.id = id
        self.text = text
        self.boundingBox = boundingBox
        self.confidence = confidence
    }
}

struct ScreenTextLine: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    let text: String
    let boundingBox: CGRect
    let observationIDs: [UUID]

    nonisolated init(
        id: UUID = UUID(),
        text: String,
        boundingBox: CGRect,
        observationIDs: [UUID]
    ) {
        self.id = id
        self.text = text
        self.boundingBox = boundingBox
        self.observationIDs = observationIDs
    }
}

struct ScreenTextBlock: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    let text: String
    let boundingBox: CGRect
    let lineIDs: [UUID]

    nonisolated init(
        id: UUID = UUID(),
        text: String,
        boundingBox: CGRect,
        lineIDs: [UUID]
    ) {
        self.id = id
        self.text = text
        self.boundingBox = boundingBox
        self.lineIDs = lineIDs
    }
}

struct ScreenTextRegion: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    let boundingBox: CGRect
    let blockIDs: [UUID]

    nonisolated init(
        id: UUID = UUID(),
        boundingBox: CGRect,
        blockIDs: [UUID]
    ) {
        self.id = id
        self.boundingBox = boundingBox
        self.blockIDs = blockIDs
    }
}

struct ScreenTextDigest: Identifiable, Codable, Equatable, Sendable {
    var id: UUID { documentID }

    let documentID: UUID
    let capturedAt: Date
    let frameHash: String
    let normalizedTextHash: String
    let layoutHash: String
}

struct DisplayScreenTextDocument: Identifiable, Codable, Equatable, Sendable {
    var id: UInt32 { displayID }

    let displayID: UInt32
    let index: Int
    let document: ScreenTextDocument

    var recognizedText: String {
        document.recognizedText
    }
}

struct MultiDisplayScreenTextDocument: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    let capturedAt: Date
    let displays: [DisplayScreenTextDocument]

    var recognizedText: String {
        displays
            .filter { !$0.recognizedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .map { display in
                "Display \(display.index + 1)\n\(display.recognizedText)"
            }
            .joined(separator: "\n\n")
    }

    var observationCount: Int {
        displays.reduce(0) { $0 + $1.document.observations.count }
    }

    var lineCount: Int {
        displays.reduce(0) { $0 + $1.document.lines.count }
    }

    var blockCount: Int {
        displays.reduce(0) { $0 + $1.document.blocks.count }
    }

    var regionCount: Int {
        displays.reduce(0) { $0 + $1.document.regions.count }
    }

    nonisolated init(
        id: UUID = UUID(),
        capturedAt: Date,
        displays: [DisplayScreenTextDocument]
    ) {
        self.id = id
        self.capturedAt = capturedAt
        self.displays = displays
    }
}
