import Foundation

protocol ScreenTextStructureClassifying: Sendable {
    func classify(_ document: ScreenTextLLMDocument) -> ScreenTextStructuredLLMDocument
}

struct HeuristicScreenTextStructureClassifier: ScreenTextStructureClassifying {
    let classifierID = "heuristic-screen-text-structure"
    let classifierVersion = "1"

    func classify(_ document: ScreenTextLLMDocument) -> ScreenTextStructuredLLMDocument {
        let annotations = document.displays.flatMap { display in
            display.blocks.map { block in
                classifyBlock(block, in: display)
            }
        }

        return ScreenTextStructuredLLMDocument(
            source: document,
            classifierID: classifierID,
            classifierVersion: classifierVersion,
            annotations: annotations
        )
    }

    private func classifyBlock(
        _ block: ScreenTextLLMBlock,
        in display: ScreenTextLLMDisplay
    ) -> ScreenTextStructureAnnotation {
        let text = block.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowercaseText = text.lowercased()
        let wordCount = block.metrics.wordCount
        let characterCount = block.metrics.characterCount
        let bounds = block.normalizedBounds

        if text.isEmpty {
            return annotation(
                block,
                role: .unknown,
                confidence: 0.2,
                reasons: ["empty block text"]
            )
        }

        if isCodeOrLog(text) {
            return annotation(
                block,
                role: .codeOrLog,
                confidence: 0.78,
                reasons: ["contains code or log punctuation patterns"]
            )
        }

        if isPriceOrNumber(text) {
            return annotation(
                block,
                role: .priceOrNumber,
                confidence: 0.74,
                reasons: ["contains currency, percentage, or numeric-heavy content"]
            )
        }

        if isButtonLike(lowercaseText, wordCount: wordCount, bounds: bounds) {
            return annotation(
                block,
                role: .buttonLike,
                confidence: 0.76,
                reasons: ["short action-like text", "compact block bounds"]
            )
        }

        if isLinkLike(lowercaseText, wordCount: wordCount) {
            return annotation(
                block,
                role: .linkLike,
                confidence: 0.7,
                reasons: ["short navigational or link-like text"]
            )
        }

        if isNavigationLike(lowercaseText, wordCount: wordCount, bounds: bounds) {
            return annotation(
                block,
                role: .navigation,
                confidence: 0.68,
                reasons: ["short text near a navigation edge"]
            )
        }

        if isFormLabel(text, wordCount: wordCount) {
            return annotation(
                block,
                role: .formLabel,
                confidence: 0.72,
                reasons: ["short label-like text"]
            )
        }

        if isInputPlaceholder(lowercaseText, wordCount: wordCount) {
            return annotation(
                block,
                role: .inputPlaceholder,
                confidence: 0.68,
                reasons: ["matches common placeholder wording"]
            )
        }

        if isTableHeader(text, wordCount: wordCount, bounds: bounds) {
            return annotation(
                block,
                role: .tableHeader,
                confidence: 0.64,
                reasons: ["short header-like text near upper area"]
            )
        }

        if characterCount >= 90 || wordCount >= 14 {
            return annotation(
                block,
                role: .paragraph,
                confidence: 0.7,
                reasons: ["long prose-like block"]
            )
        }

        if isChatMessage(text, characterCount: characterCount, bounds: bounds) {
            return annotation(
                block,
                role: .chatMessage,
                confidence: 0.62,
                reasons: ["message-length text in conversation-like horizontal bounds"]
            )
        }

        if isHeadingLike(text, wordCount: wordCount, bounds: bounds, display: display) {
            return annotation(
                block,
                role: .heading,
                confidence: 0.72,
                reasons: ["short prominent text", "appears high or early in reading order"]
            )
        }

        if isMetadata(lowercaseText, wordCount: wordCount) {
            return annotation(
                block,
                role: .metadata,
                confidence: 0.64,
                reasons: ["date, time, status, or small descriptive metadata pattern"]
            )
        }

        if wordCount <= 8 {
            return annotation(
                block,
                role: .tableCell,
                confidence: 0.48,
                reasons: ["short standalone text without stronger structural signal"]
            )
        }

        return annotation(
            block,
            role: .unknown,
            confidence: 0.4,
            reasons: ["no strong structural rule matched"]
        )
    }

    private func annotation(
        _ block: ScreenTextLLMBlock,
        role: ScreenTextStructureRole,
        confidence: Double,
        reasons: [String]
    ) -> ScreenTextStructureAnnotation {
        ScreenTextStructureAnnotation(
            alias: block.alias,
            targetKind: .block,
            role: role,
            confidence: confidence,
            reasons: reasons
        )
    }

    private func isButtonLike(
        _ lowercaseText: String,
        wordCount: Int,
        bounds: ScreenTextLLMBounds
    ) -> Bool {
        guard wordCount <= 5, bounds.width <= 0.45, bounds.height <= 0.12 else {
            return false
        }

        let exactActions: Set<String> = [
            "ok",
            "cancel",
            "done",
            "save",
            "send",
            "submit",
            "continue",
            "next",
            "back",
            "close",
            "apply",
            "confirm",
            "sign in",
            "log in",
            "create account",
            "get started",
            "learn more"
        ]

        if exactActions.contains(lowercaseText) {
            return true
        }

        return lowercaseText.hasPrefix("save ")
            || lowercaseText.hasPrefix("add ")
            || lowercaseText.hasPrefix("create ")
            || lowercaseText.hasPrefix("open ")
            || lowercaseText.hasPrefix("view ")
            || lowercaseText.hasPrefix("start ")
    }

    private func isLinkLike(_ lowercaseText: String, wordCount: Int) -> Bool {
        guard wordCount <= 7 else { return false }

        return lowercaseText.hasPrefix("http://")
            || lowercaseText.hasPrefix("https://")
            || lowercaseText.contains("www.")
            || lowercaseText.contains(".com")
            || lowercaseText == "terms"
            || lowercaseText == "privacy"
            || lowercaseText == "forgot password?"
            || lowercaseText == "learn more"
    }

    private func isNavigationLike(
        _ lowercaseText: String,
        wordCount: Int,
        bounds: ScreenTextLLMBounds
    ) -> Bool {
        guard wordCount <= 4 else { return false }

        let nearTop = bounds.y <= 0.18
        let nearSide = bounds.x <= 0.18 || bounds.x + bounds.width >= 0.82
        let navWords: Set<String> = [
            "home",
            "search",
            "settings",
            "profile",
            "account",
            "dashboard",
            "inbox",
            "help",
            "files",
            "edit",
            "view",
            "window"
        ]

        return (nearTop || nearSide) && navWords.contains(lowercaseText)
    }

    private func isFormLabel(_ text: String, wordCount: Int) -> Bool {
        let lowercaseText = text.lowercased()
        guard wordCount <= 5 else { return false }

        if text.hasSuffix(":") {
            return true
        }

        let labelWords: Set<String> = [
            "name",
            "email",
            "password",
            "username",
            "phone",
            "address",
            "company",
            "title",
            "description",
            "search",
            "date",
            "amount"
        ]

        return labelWords.contains(lowercaseText)
    }

    private func isInputPlaceholder(_ lowercaseText: String, wordCount: Int) -> Bool {
        guard wordCount <= 8 else { return false }

        return lowercaseText.hasPrefix("enter ")
            || lowercaseText.hasPrefix("type ")
            || lowercaseText.hasPrefix("search ")
            || lowercaseText.hasPrefix("select ")
            || lowercaseText.hasPrefix("choose ")
            || lowercaseText.contains("placeholder")
    }

    private func isTableHeader(
        _ text: String,
        wordCount: Int,
        bounds: ScreenTextLLMBounds
    ) -> Bool {
        guard wordCount <= 4, bounds.y <= 0.35 else { return false }

        let lowercaseText = text.lowercased()
        let headerWords: Set<String> = [
            "status",
            "date",
            "name",
            "type",
            "amount",
            "total",
            "price",
            "owner",
            "created",
            "updated"
        ]

        return headerWords.contains(lowercaseText)
    }

    private func isChatMessage(
        _ text: String,
        characterCount: Int,
        bounds: ScreenTextLLMBounds
    ) -> Bool {
        guard characterCount >= 12, characterCount <= 280 else { return false }

        let hasSentencePunctuation = text.contains(".") || text.contains("?") || text.contains("!")
        let conversationWidth = bounds.width >= 0.25 && bounds.width <= 0.85
        let insetFromEdges = bounds.x >= 0.05 && bounds.x + bounds.width <= 0.95

        return hasSentencePunctuation && conversationWidth && insetFromEdges
    }

    private func isHeadingLike(
        _ text: String,
        wordCount: Int,
        bounds: ScreenTextLLMBounds,
        display: ScreenTextLLMDisplay
    ) -> Bool {
        guard wordCount <= 10 else { return false }

        let appearsHigh = bounds.y <= 0.28
        let appearsEarly = display.blocks.first?.text == text
        let titleCaseOrShort = text.first?.isUppercase == true || wordCount <= 3

        return titleCaseOrShort && (appearsHigh || appearsEarly)
    }

    private func isMetadata(_ lowercaseText: String, wordCount: Int) -> Bool {
        guard wordCount <= 8 else { return false }

        if lowercaseText.contains("updated")
            || lowercaseText.contains("created")
            || lowercaseText.contains("edited")
            || lowercaseText.contains("version")
            || lowercaseText.contains("last seen") {
            return true
        }

        let hasTimeSeparator = lowercaseText.contains(":")
        let hasDateSeparator = lowercaseText.contains("/") || lowercaseText.contains("-")
        let hasDigit = lowercaseText.contains { $0.isNumber }

        return hasDigit && (hasTimeSeparator || hasDateSeparator)
    }

    private func isPriceOrNumber(_ text: String) -> Bool {
        let digitCount = text.filter(\.isNumber).count
        guard digitCount > 0 else { return false }

        if text.contains("$") || text.contains("USD") || text.contains("EUR") || text.contains("GBP") || text.contains("%") {
            return true
        }

        let nonWhitespaceCount = text.filter { !$0.isWhitespace }.count
        return nonWhitespaceCount > 0 && Double(digitCount) / Double(nonWhitespaceCount) >= 0.55
    }

    private func isCodeOrLog(_ text: String) -> Bool {
        let lowercaseText = text.lowercased()

        if lowercaseText.contains(" error ")
            || lowercaseText.hasPrefix("error")
            || lowercaseText.contains(" warning ")
            || lowercaseText.hasPrefix("warning")
            || lowercaseText.contains("exception")
            || lowercaseText.contains("stack trace") {
            return true
        }

        let codeTokens = ["{", "}", "();", "=>", "==", "!=", "let ", "var ", "func ", "import "]
        return codeTokens.contains { text.contains($0) }
    }
}
