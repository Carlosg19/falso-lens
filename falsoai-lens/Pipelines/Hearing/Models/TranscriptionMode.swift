import Foundation

enum TranscriptionMode: Sendable, Equatable, CaseIterable, Identifiable {
    case transcribeOriginalLanguage
    case translateToEnglish

    var id: Self { self }

    var displayName: String {
        switch self {
        case .transcribeOriginalLanguage:
            return "Original"
        case .translateToEnglish:
            return "English (translate)"
        }
    }

    var transcriptValue: String {
        switch self {
        case .transcribeOriginalLanguage:
            return "transcribe_original_language"
        case .translateToEnglish:
            return "translate_to_english"
        }
    }
}
