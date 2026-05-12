import CoreGraphics
import Foundation

actor ScreenTextEncounterMemory {
    private struct TextUnit: Sendable {
        let text: String
        let normalizedTextHash: String
        let source: ScreenTextEncounterSource
    }

    private let windowSeconds: TimeInterval
    private let maxEncounters: Int
    private var encountersByHash: [String: ScreenTextEncounter] = [:]

    init(
        windowSeconds: TimeInterval = 5 * 60,
        maxEncounters: Int = 1_500
    ) {
        self.windowSeconds = max(1, windowSeconds)
        self.maxEncounters = max(1, maxEncounters)
    }

    func ingest(_ snapshot: RealtimeScreenTextSnapshot) -> ScreenTextEncounterSummary {
        let prunedCount = prune(referenceDate: snapshot.capturedAt)
        var newCount = 0
        var updatedCount = 0

        for unit in textUnits(from: snapshot) {
            if let existing = encountersByHash[unit.normalizedTextHash] {
                encountersByHash[unit.normalizedTextHash] = ScreenTextEncounter(
                    text: existing.text,
                    normalizedTextHash: existing.normalizedTextHash,
                    firstSeenAt: existing.firstSeenAt,
                    lastSeenAt: snapshot.capturedAt,
                    seenCount: existing.seenCount + 1,
                    latestSource: unit.source
                )
                updatedCount += 1
            } else {
                encountersByHash[unit.normalizedTextHash] = ScreenTextEncounter(
                    text: unit.text,
                    normalizedTextHash: unit.normalizedTextHash,
                    firstSeenAt: snapshot.capturedAt,
                    lastSeenAt: snapshot.capturedAt,
                    seenCount: 1,
                    latestSource: unit.source
                )
                newCount += 1
            }
        }

        trimToMaxEncounters()

        return ScreenTextEncounterSummary(
            totalEncounterCount: encountersByHash.count,
            newEncounterCount: newCount,
            updatedEncounterCount: updatedCount,
            prunedEncounterCount: prunedCount
        )
    }

    func recentEncounters(referenceDate: Date = Date()) -> [ScreenTextEncounter] {
        _ = prune(referenceDate: referenceDate)
        return encountersByHash.values.sorted { lhs, rhs in
            if lhs.firstSeenAt != rhs.firstSeenAt {
                return lhs.firstSeenAt < rhs.firstSeenAt
            }

            return lhs.text.localizedStandardCompare(rhs.text) == .orderedAscending
        }
    }

    func clear() {
        encountersByHash.removeAll()
    }

    @discardableResult
    private func prune(referenceDate: Date) -> Int {
        let oldestAllowedDate = referenceDate.addingTimeInterval(-windowSeconds)
        let originalCount = encountersByHash.count
        encountersByHash = encountersByHash.filter { _, encounter in
            encounter.lastSeenAt >= oldestAllowedDate
        }
        return originalCount - encountersByHash.count
    }

    private func trimToMaxEncounters() {
        guard encountersByHash.count > maxEncounters else { return }

        let encountersToKeep = encountersByHash.values
            .sorted { lhs, rhs in
                if lhs.lastSeenAt != rhs.lastSeenAt {
                    return lhs.lastSeenAt > rhs.lastSeenAt
                }

                return lhs.firstSeenAt > rhs.firstSeenAt
            }
            .prefix(maxEncounters)

        encountersByHash = Dictionary(
            uniqueKeysWithValues: encountersToKeep.map { ($0.normalizedTextHash, $0) }
        )
    }

    private func textUnits(from snapshot: RealtimeScreenTextSnapshot) -> [TextUnit] {
        snapshot.document.displays.flatMap { display in
            let lineUnits = display.document.lines.compactMap { line in
                textUnit(
                    text: line.text,
                    display: display,
                    bounds: line.boundingBox
                )
            }

            if !lineUnits.isEmpty {
                return lineUnits
            }

            return display.document.observations.compactMap { observation in
                textUnit(
                    text: observation.text,
                    display: display,
                    bounds: observation.boundingBox
                )
            }
        }
    }

    private func textUnit(
        text: String,
        display: DisplayScreenTextDocument,
        bounds: CGRect
    ) -> TextUnit? {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedText = ScreenTextHasher.normalizeText(trimmedText)

        guard normalizedText.count > 1 else {
            return nil
        }

        return TextUnit(
            text: trimmedText,
            normalizedTextHash: ScreenTextHasher.hashNormalizedText(normalizedText),
            source: ScreenTextEncounterSource(
                displayID: display.displayID,
                displayIndex: display.index,
                bounds: bounds
            )
        )
    }
}

#if DEBUG
extension ScreenTextEncounterMemory {
    static func runSmokeChecks() async {
        await verifyDuplicateLinesMerge()
        await verifyOldEncountersPrune()
    }

    private static func verifyDuplicateLinesMerge() async {
        let memory = ScreenTextEncounterMemory(windowSeconds: 300)
        let capturedAt = Date()
        let snapshot = makeSnapshot(
            capturedAt: capturedAt,
            lines: [
                ScreenTextLine(
                    text: "Limited time offer",
                    boundingBox: CGRect(x: 10, y: 10, width: 100, height: 20),
                    observationIDs: []
                ),
                ScreenTextLine(
                    text: " limited   time OFFER ",
                    boundingBox: CGRect(x: 10, y: 40, width: 100, height: 20),
                    observationIDs: []
                )
            ]
        )

        let summary = await memory.ingest(snapshot)
        let encounters = await memory.recentEncounters(referenceDate: capturedAt)

        assert(summary.newEncounterCount == 1, "Expected normalized duplicate lines to create one new encounter")
        assert(summary.updatedEncounterCount == 1, "Expected normalized duplicate lines to update the first encounter")
        assert(encounters.count == 1, "Expected one deduplicated encounter")
        assert(encounters[0].seenCount == 2, "Expected duplicate line seen count to be 2")
    }

    private static func verifyOldEncountersPrune() async {
        let memory = ScreenTextEncounterMemory(windowSeconds: 300)
        let oldDate = Date(timeIntervalSince1970: 1_000)
        let newDate = oldDate.addingTimeInterval(301)

        _ = await memory.ingest(
            makeSnapshot(
                capturedAt: oldDate,
                lines: [
                    ScreenTextLine(
                        text: "Old text",
                        boundingBox: CGRect(x: 0, y: 0, width: 10, height: 10),
                        observationIDs: []
                    )
                ]
            )
        )

        _ = await memory.ingest(
            makeSnapshot(
                capturedAt: newDate,
                lines: [
                    ScreenTextLine(
                        text: "New text",
                        boundingBox: CGRect(x: 0, y: 0, width: 10, height: 10),
                        observationIDs: []
                    )
                ]
            )
        )

        let encounters = await memory.recentEncounters(referenceDate: newDate)
        assert(encounters.map(\.text) == ["New text"], "Expected encounters older than five minutes to be pruned")
    }

    private static func makeSnapshot(
        capturedAt: Date,
        lines: [ScreenTextLine]
    ) -> RealtimeScreenTextSnapshot {
        let displayDocument = DisplayScreenTextDocument(
            displayID: 1,
            index: 0,
            document: ScreenTextDocument(
                capturedAt: capturedAt,
                frameSize: CGSize(width: 200, height: 200),
                frameHash: "frame-\(capturedAt.timeIntervalSince1970)",
                normalizedTextHash: ScreenTextHasher.hashNormalizedText(lines.map(\.text).joined(separator: "\n")),
                layoutHash: "layout-\(capturedAt.timeIntervalSince1970)",
                observations: [],
                lines: lines,
                blocks: [],
                regions: []
            )
        )
        let document = MultiDisplayScreenTextDocument(
            capturedAt: capturedAt,
            displays: [displayDocument]
        )

        return RealtimeScreenTextSnapshot(
            sessionID: UUID(),
            sequenceNumber: 1,
            capturedAt: capturedAt,
            document: document,
            recognizedText: document.recognizedText,
            markdownExport: document.recognizedText,
            compactJSONExport: "{}",
            chunkCount: 1,
            displayCount: 1,
            observationCount: document.observationCount,
            lineCount: document.lineCount,
            blockCount: document.blockCount,
            regionCount: document.regionCount,
            aggregateTextHash: ScreenTextHasher.hashAggregateText(document),
            aggregateLayoutHash: ScreenTextHasher.hashAggregateLayout(document),
            displayFrameHashes: ["frame-\(capturedAt.timeIntervalSince1970)"],
            reusedDisplayCount: 0,
            ocrDisplayCount: 1,
            elapsedSeconds: 0
        )
    }
}
#endif
