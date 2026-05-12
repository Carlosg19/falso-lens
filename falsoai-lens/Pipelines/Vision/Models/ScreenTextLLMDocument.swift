import CoreGraphics
import Foundation

struct ScreenTextLLMDocument: Codable, Equatable, Sendable {
    let sourceDocumentID: UUID
    let capturedAt: Date
    let displayCount: Int
    let observationCount: Int
    let lineCount: Int
    let blockCount: Int
    let regionCount: Int
    let displays: [ScreenTextLLMDisplay]
}

struct ScreenTextLLMDisplay: Codable, Equatable, Sendable {
    let alias: String
    let displayID: UInt32
    let index: Int
    let capturedAt: Date
    let frameSize: ScreenTextLLMSize
    let frameHash: String
    let normalizedTextHash: String
    let layoutHash: String
    let text: String
    let regions: [ScreenTextLLMRegion]
    let blocks: [ScreenTextLLMBlock]
    let lines: [ScreenTextLLMLine]
    let observations: [ScreenTextLLMObservation]
}

struct ScreenTextLLMRegion: Codable, Equatable, Sendable {
    let alias: String
    let sourceID: UUID
    let readingOrder: Int
    let bounds: ScreenTextLLMBounds
    let normalizedBounds: ScreenTextLLMBounds
    let blockAliases: [String]
    let metrics: ScreenTextLLMMetrics
}

struct ScreenTextLLMBlock: Codable, Equatable, Sendable {
    let alias: String
    let sourceID: UUID
    let readingOrder: Int
    let text: String
    let bounds: ScreenTextLLMBounds
    let normalizedBounds: ScreenTextLLMBounds
    let lineAliases: [String]
    let metrics: ScreenTextLLMMetrics
}

struct ScreenTextLLMLine: Codable, Equatable, Sendable {
    let alias: String
    let sourceID: UUID
    let readingOrder: Int
    let text: String
    let bounds: ScreenTextLLMBounds
    let normalizedBounds: ScreenTextLLMBounds
    let observationAliases: [String]
    let metrics: ScreenTextLLMMetrics
}

struct ScreenTextLLMObservation: Codable, Equatable, Sendable {
    let alias: String
    let sourceID: UUID
    let readingOrder: Int
    let text: String
    let bounds: ScreenTextLLMBounds
    let normalizedBounds: ScreenTextLLMBounds
    let confidence: Float
    let metrics: ScreenTextLLMMetrics
}

struct ScreenTextLLMChunk: Codable, Equatable, Sendable {
    let alias: String
    let displayAlias: String
    let regionAliases: [String]
    let text: String
    let characterCount: Int
}

struct ScreenTextLLMBounds: Codable, Equatable, Sendable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double
}

struct ScreenTextLLMSize: Codable, Equatable, Sendable {
    let width: Double
    let height: Double
}

struct ScreenTextLLMMetrics: Codable, Equatable, Sendable {
    let characterCount: Int
    let wordCount: Int
    let areaRatio: Double
}
