import Foundation

enum ScreenTextStructureRole: String, Codable, CaseIterable, Equatable, Sendable {
    case heading
    case paragraph
    case listItem
    case buttonLike
    case linkLike
    case navigation
    case formLabel
    case formValue
    case inputPlaceholder
    case tableHeader
    case tableCell
    case dialogTitle
    case dialogBody
    case toastOrBanner
    case chatMessage
    case codeOrLog
    case priceOrNumber
    case metadata
    case ad
    case chrome
    case unknown
}

enum ScreenTextStructureTargetKind: String, Codable, Equatable, Sendable {
    case block
}

struct ScreenTextStructureAnnotation: Codable, Equatable, Sendable {
    let alias: String
    let targetKind: ScreenTextStructureTargetKind
    let role: ScreenTextStructureRole
    let confidence: Double
    let reasons: [String]

    nonisolated init(
        alias: String,
        targetKind: ScreenTextStructureTargetKind,
        role: ScreenTextStructureRole,
        confidence: Double,
        reasons: [String]
    ) {
        self.alias = alias
        self.targetKind = targetKind
        self.role = role
        self.confidence = min(max(confidence, 0), 1)
        self.reasons = reasons
    }
}

struct ScreenTextStructuredLLMDocument: Codable, Equatable, Sendable {
    let source: ScreenTextLLMDocument
    let classifierID: String
    let classifierVersion: String
    let generatedAt: Date
    let annotations: [ScreenTextStructureAnnotation]

    nonisolated init(
        source: ScreenTextLLMDocument,
        classifierID: String,
        classifierVersion: String,
        generatedAt: Date = Date(),
        annotations: [ScreenTextStructureAnnotation]
    ) {
        self.source = source
        self.classifierID = classifierID
        self.classifierVersion = classifierVersion
        self.generatedAt = generatedAt
        self.annotations = annotations
    }

    func annotation(for alias: String) -> ScreenTextStructureAnnotation? {
        annotations.first { $0.alias == alias }
    }
}
