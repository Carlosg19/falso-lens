import Foundation

actor ScreenTextMemory {
    private let maxDocuments: Int
    private let maxAge: TimeInterval
    private var currentDocument: ScreenTextDocument?
    private var documentsByFrameHash: [String: ScreenTextDocument] = [:]
    private var recentDigests: [ScreenTextDigest] = []

    init(
        maxDocuments: Int = 20,
        maxAge: TimeInterval = 10 * 60
    ) {
        self.maxDocuments = max(1, maxDocuments)
        self.maxAge = maxAge
    }

    func cachedDocument(forFrameHash frameHash: String) -> ScreenTextDocument? {
        pruneExpiredDocuments(referenceDate: Date())
        return documentsByFrameHash[frameHash]
    }

    func latestDocument() -> ScreenTextDocument? {
        currentDocument
    }

    func digests() -> [ScreenTextDigest] {
        recentDigests
    }

    @discardableResult
    func store(_ document: ScreenTextDocument) -> ScreenTextDocument {
        pruneExpiredDocuments(referenceDate: document.capturedAt)

        if let currentDocument,
           currentDocument.normalizedTextHash == document.normalizedTextHash,
           currentDocument.layoutHash == document.layoutHash {
            documentsByFrameHash[document.frameHash] = currentDocument
            return currentDocument
        }

        currentDocument = document
        documentsByFrameHash[document.frameHash] = document
        recentDigests.insert(
            ScreenTextDigest(
                documentID: document.id,
                capturedAt: document.capturedAt,
                frameHash: document.frameHash,
                normalizedTextHash: document.normalizedTextHash,
                layoutHash: document.layoutHash
            ),
            at: 0
        )
        trimToMaxDocuments()
        return document
    }

    private func pruneExpiredDocuments(referenceDate: Date) {
        guard maxAge > 0 else {
            trimToMaxDocuments()
            return
        }

        let oldestAllowedDate = referenceDate.addingTimeInterval(-maxAge)
        recentDigests.removeAll { $0.capturedAt < oldestAllowedDate }
        let allowedFrameHashes = Set(recentDigests.map(\.frameHash))
        documentsByFrameHash = documentsByFrameHash.filter { allowedFrameHashes.contains($0.key) }

        if let currentDocument,
           currentDocument.capturedAt < oldestAllowedDate {
            self.currentDocument = nil
        }
    }

    private func trimToMaxDocuments() {
        guard recentDigests.count > maxDocuments else { return }

        let removedDigests = recentDigests.dropFirst(maxDocuments)
        recentDigests = Array(recentDigests.prefix(maxDocuments))

        for digest in removedDigests {
            documentsByFrameHash[digest.frameHash] = nil
        }
    }
}
