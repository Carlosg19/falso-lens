import Foundation

enum TranscriptSimilarityHelpers {
    nonisolated static func normalizedWords(_ text: String) -> [String] {
        let foldedText = text.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: .current
        )
        let allowedCharacters = CharacterSet.alphanumerics.union(.whitespacesAndNewlines)
        let cleanedScalars = foldedText.unicodeScalars.map { scalar in
            allowedCharacters.contains(scalar) ? Character(scalar) : " "
        }

        return String(cleanedScalars)
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
    }

    nonisolated static func isLikelySameUtterance(_ lhs: String, _ rhs: String?) -> Bool {
        guard let rhs else { return false }

        let lhsWords = normalizedWords(lhs)
        let rhsWords = normalizedWords(rhs)
        guard !lhsWords.isEmpty, !rhsWords.isEmpty else { return false }

        let lhsJoined = lhsWords.joined(separator: " ")
        let rhsJoined = rhsWords.joined(separator: " ")
        if lhsJoined == rhsJoined {
            return true
        }

        let shorter = lhsJoined.count <= rhsJoined.count ? lhsJoined : rhsJoined
        let longer = lhsJoined.count > rhsJoined.count ? lhsJoined : rhsJoined
        if shorter.count >= 24, longer.contains(shorter) {
            return true
        }

        let lhsSet = Set(lhsWords)
        let rhsSet = Set(rhsWords)
        let overlapCount = lhsSet.intersection(rhsSet).count
        let smallerCount = min(lhsSet.count, rhsSet.count)
        guard smallerCount >= 4 else { return false }

        return Double(overlapCount) / Double(smallerCount) >= 0.82
    }

    nonisolated static func absoluteCorrelation(_ lhs: [Float], _ rhs: [Float]) -> Double {
        let count = min(lhs.count, rhs.count)
        guard count > 0 else { return 0 }

        var dotProduct = 0.0
        var lhsEnergy = 0.0
        var rhsEnergy = 0.0

        for index in 0..<count {
            let lhsSample = Double(lhs[index])
            let rhsSample = Double(rhs[index])
            dotProduct += lhsSample * rhsSample
            lhsEnergy += lhsSample * lhsSample
            rhsEnergy += rhsSample * rhsSample
        }

        guard lhsEnergy > 0, rhsEnergy > 0 else { return 0 }
        return abs(dotProduct / sqrt(lhsEnergy * rhsEnergy))
    }
}
