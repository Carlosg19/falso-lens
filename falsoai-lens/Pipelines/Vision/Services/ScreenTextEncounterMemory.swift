import CoreGraphics
import Foundation

actor ScreenTextEncounterMemory {
    private struct TextUnit: Sendable {
        let text: String
        let normalizedTextHash: String
        let displayID: UInt32
        let displayIndex: Int
        let bounds: CGRect
        let role: ScreenTextStructureRole
        let blockAlias: String?
    }

    static let maxSightingsPerEncounter = 60

    private let windowSeconds: TimeInterval
    private let maxEncounters: Int
    private var encountersByKey: [String: ScreenTextEncounter] = [:]

    init(
        windowSeconds: TimeInterval = 60,
        maxEncounters: Int = 1_500
    ) {
        self.windowSeconds = max(1, windowSeconds)
        self.maxEncounters = max(1, maxEncounters)
    }

    func ingest(
        _ snapshot: RealtimeScreenTextSnapshot,
        classifiedDocument: ScreenTextStructuredLLMDocument? = nil
    ) -> ScreenTextEncounterSummary {
        let prunedCount = prune(referenceDate: snapshot.capturedAt)
        var newCount = 0
        var updatedCount = 0

        for unit in textUnits(from: snapshot, classifiedDocument: classifiedDocument) {
            let key = Self.key(displayID: unit.displayID, normalizedTextHash: unit.normalizedTextHash)
            let sighting = ScreenTextEncounterSighting(
                bounds: unit.bounds,
                sightedAt: snapshot.capturedAt,
                role: unit.role,
                blockAlias: unit.blockAlias
            )

            if let existing = encountersByKey[key] {
                var sightings = existing.sightings
                sightings.append(sighting)
                if sightings.count > Self.maxSightingsPerEncounter {
                    sightings.removeFirst(sightings.count - Self.maxSightingsPerEncounter)
                }

                var roleCounts = existing.roleCounts
                roleCounts[unit.role, default: 0] += 1

                encountersByKey[key] = ScreenTextEncounter(
                    text: existing.text,
                    normalizedTextHash: existing.normalizedTextHash,
                    displayID: existing.displayID,
                    displayIndex: existing.displayIndex,
                    firstSeenAt: existing.firstSeenAt,
                    lastSeenAt: snapshot.capturedAt,
                    seenCount: existing.seenCount + 1,
                    sightings: sightings,
                    roleCounts: roleCounts
                )
                updatedCount += 1
            } else {
                encountersByKey[key] = ScreenTextEncounter(
                    text: unit.text,
                    normalizedTextHash: unit.normalizedTextHash,
                    displayID: unit.displayID,
                    displayIndex: unit.displayIndex,
                    firstSeenAt: snapshot.capturedAt,
                    lastSeenAt: snapshot.capturedAt,
                    seenCount: 1,
                    sightings: [sighting],
                    roleCounts: [unit.role: 1]
                )
                newCount += 1
            }
        }

        trimToMaxEncounters()

        return ScreenTextEncounterSummary(
            totalEncounterCount: encountersByKey.count,
            newEncounterCount: newCount,
            updatedEncounterCount: updatedCount,
            prunedEncounterCount: prunedCount
        )
    }

    func recentEncounters(referenceDate: Date = Date()) -> [ScreenTextEncounter] {
        _ = prune(referenceDate: referenceDate)
        return encountersByKey.values.sorted { lhs, rhs in
            if lhs.firstSeenAt != rhs.firstSeenAt {
                return lhs.firstSeenAt < rhs.firstSeenAt
            }

            return lhs.text.localizedStandardCompare(rhs.text) == .orderedAscending
        }
    }

    func clear() {
        encountersByKey.removeAll()
    }

    @discardableResult
    private func prune(referenceDate: Date) -> Int {
        let oldestAllowedDate = referenceDate.addingTimeInterval(-windowSeconds)
        let originalCount = encountersByKey.count
        encountersByKey = encountersByKey.filter { _, encounter in
            encounter.lastSeenAt >= oldestAllowedDate
        }
        return originalCount - encountersByKey.count
    }

    private func trimToMaxEncounters() {
        guard encountersByKey.count > maxEncounters else { return }

        let encountersToKeep = encountersByKey
            .sorted { lhs, rhs in
                if lhs.value.lastSeenAt != rhs.value.lastSeenAt {
                    return lhs.value.lastSeenAt > rhs.value.lastSeenAt
                }

                return lhs.value.firstSeenAt > rhs.value.firstSeenAt
            }
            .prefix(maxEncounters)

        encountersByKey = Dictionary(uniqueKeysWithValues: encountersToKeep.map { ($0.key, $0.value) })
    }

    private static func key(displayID: UInt32, normalizedTextHash: String) -> String {
        "\(displayID)|\(normalizedTextHash)"
    }

    private func textUnits(
        from snapshot: RealtimeScreenTextSnapshot,
        classifiedDocument: ScreenTextStructuredLLMDocument?
    ) -> [TextUnit] {
        if let classifiedDocument {
            return classifiedTextUnits(from: classifiedDocument)
        }
        return fallbackTextUnits(from: snapshot)
    }

    private func classifiedTextUnits(from classifiedDocument: ScreenTextStructuredLLMDocument) -> [TextUnit] {
        classifiedDocument.source.displays.flatMap { display in
            display.blocks.compactMap { block -> TextUnit? in
                let annotation = classifiedDocument.annotation(for: block.alias)
                let role = annotation?.role ?? .unknown
                return textUnit(
                    text: block.text,
                    displayID: display.displayID,
                    displayIndex: display.index,
                    bounds: cgRect(from: block.bounds),
                    role: role,
                    blockAlias: block.alias
                )
            }
        }
    }

    private func fallbackTextUnits(from snapshot: RealtimeScreenTextSnapshot) -> [TextUnit] {
        snapshot.document.displays.flatMap { display in
            let lineUnits = display.document.lines.compactMap { line in
                textUnit(
                    text: line.text,
                    displayID: display.displayID,
                    displayIndex: display.index,
                    bounds: line.boundingBox,
                    role: .unknown,
                    blockAlias: nil
                )
            }

            if !lineUnits.isEmpty {
                return lineUnits
            }

            return display.document.observations.compactMap { observation in
                textUnit(
                    text: observation.text,
                    displayID: display.displayID,
                    displayIndex: display.index,
                    bounds: observation.boundingBox,
                    role: .unknown,
                    blockAlias: nil
                )
            }
        }
    }

    private func textUnit(
        text: String,
        displayID: UInt32,
        displayIndex: Int,
        bounds: CGRect,
        role: ScreenTextStructureRole,
        blockAlias: String?
    ) -> TextUnit? {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedText = ScreenTextHasher.normalizeText(trimmedText)

        guard normalizedText.count > 1 else {
            return nil
        }

        return TextUnit(
            text: trimmedText,
            normalizedTextHash: ScreenTextHasher.hashNormalizedText(normalizedText),
            displayID: displayID,
            displayIndex: displayIndex,
            bounds: bounds,
            role: role,
            blockAlias: blockAlias
        )
    }

    private func cgRect(from bounds: ScreenTextLLMBounds) -> CGRect {
        CGRect(x: bounds.x, y: bounds.y, width: bounds.width, height: bounds.height)
    }
}

#if DEBUG
extension ScreenTextEncounterMemory {
    static func runSmokeChecks() async {
        await verifyDuplicateLinesMerge()
        await verifyOldEncountersPrune()
        await verifySameTextOnDifferentDisplaysSplits()
        await verifySightingsAccumulateAcrossSamples()
        await verifyClassifiedRolesAreCarriedThroughIngest()
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
        assert(encounters.map(\.text) == ["New text"], "Expected encounters older than the window to be pruned")
    }

    private static func verifySameTextOnDifferentDisplaysSplits() async {
        let memory = ScreenTextEncounterMemory(windowSeconds: 60)
        let capturedAt = Date()

        let displayOne = makeDisplay(
            displayID: 1,
            index: 0,
            capturedAt: capturedAt,
            lines: [
                ScreenTextLine(
                    text: "Submit",
                    boundingBox: CGRect(x: 10, y: 10, width: 80, height: 24),
                    observationIDs: []
                )
            ]
        )
        let displayTwo = makeDisplay(
            displayID: 2,
            index: 1,
            capturedAt: capturedAt,
            lines: [
                ScreenTextLine(
                    text: "Submit",
                    boundingBox: CGRect(x: 50, y: 200, width: 80, height: 24),
                    observationIDs: []
                )
            ]
        )

        _ = await memory.ingest(makeSnapshot(capturedAt: capturedAt, displays: [displayOne, displayTwo]))
        let encounters = await memory.recentEncounters(referenceDate: capturedAt)

        assert(encounters.count == 2,
               "Expected same text on two displays to produce two encounters, got \(encounters.count)")
        let displayIDs = Set(encounters.map(\.displayID))
        assert(displayIDs == Set([1, 2]),
               "Expected encounters to be split across display IDs 1 and 2")
    }

    private static func verifySightingsAccumulateAcrossSamples() async {
        let memory = ScreenTextEncounterMemory(windowSeconds: 60)
        let firstDate = Date(timeIntervalSince1970: 100)
        let secondDate = firstDate.addingTimeInterval(1)
        let thirdDate = firstDate.addingTimeInterval(2)

        for date in [firstDate, secondDate, thirdDate] {
            _ = await memory.ingest(
                makeSnapshot(
                    capturedAt: date,
                    displays: [
                        makeDisplay(
                            displayID: 1,
                            index: 0,
                            capturedAt: date,
                            lines: [
                                ScreenTextLine(
                                    text: "Hello",
                                    boundingBox: CGRect(x: 0, y: 0, width: 10, height: 10),
                                    observationIDs: []
                                )
                            ]
                        )
                    ]
                )
            )
        }

        let encounters = await memory.recentEncounters(referenceDate: thirdDate)
        assert(encounters.count == 1, "Expected one encounter accumulating sightings")
        assert(encounters[0].sightings.count == 3,
               "Expected three sightings for repeated text, got \(encounters[0].sightings.count)")
        assert(encounters[0].sightings.map(\.sightedAt) == [firstDate, secondDate, thirdDate],
               "Expected sightings to preserve chronological order")
    }

    private static func verifyClassifiedRolesAreCarriedThroughIngest() async {
        let memory = ScreenTextEncounterMemory(windowSeconds: 60)
        let capturedAt = Date()

        let blockText = "Sponsored"
        let block = ScreenTextLLMBlock(
            alias: "d1.b1",
            sourceID: UUID(),
            readingOrder: 1,
            text: blockText,
            bounds: ScreenTextLLMBounds(x: 0.4, y: 0.4, width: 0.2, height: 0.05),
            normalizedBounds: ScreenTextLLMBounds(x: 0.4, y: 0.4, width: 0.2, height: 0.05),
            lineAliases: [],
            metrics: ScreenTextLLMMetrics(characterCount: blockText.count, wordCount: 1, areaRatio: 0.01)
        )
        let display = ScreenTextLLMDisplay(
            alias: "d1",
            displayID: 1,
            index: 0,
            capturedAt: capturedAt,
            frameSize: ScreenTextLLMSize(width: 1.0, height: 1.0),
            frameHash: "frame",
            normalizedTextHash: "text",
            layoutHash: "layout",
            text: blockText,
            regions: [],
            blocks: [block],
            lines: [],
            observations: []
        )
        let llmDocument = ScreenTextLLMDocument(
            sourceDocumentID: UUID(),
            capturedAt: capturedAt,
            displayCount: 1,
            observationCount: 0,
            lineCount: 0,
            blockCount: 1,
            regionCount: 0,
            displays: [display]
        )
        let classified = await HeuristicScreenTextStructureClassifier().classify(llmDocument)
        let snapshot = makeSnapshot(
            capturedAt: capturedAt,
            displays: [
                makeDisplay(
                    displayID: 1,
                    index: 0,
                    capturedAt: capturedAt,
                    lines: [
                        ScreenTextLine(
                            text: blockText,
                            boundingBox: CGRect(x: 0.4, y: 0.4, width: 0.2, height: 0.05),
                            observationIDs: []
                        )
                    ]
                )
            ]
        )

        _ = await memory.ingest(snapshot, classifiedDocument: classified)
        let encounters = await memory.recentEncounters(referenceDate: capturedAt)

        assert(encounters.count == 1, "Expected one encounter for classified ad block")
        assert(encounters[0].dominantRole == .ad,
               "Expected dominant role to be .ad, got \(encounters[0].dominantRole.rawValue)")
        assert(encounters[0].sightings.first?.blockAlias == "d1.b1",
               "Expected sighting to carry block alias from classifier")
    }

    private static func makeSnapshot(
        capturedAt: Date,
        lines: [ScreenTextLine]
    ) -> RealtimeScreenTextSnapshot {
        makeSnapshot(
            capturedAt: capturedAt,
            displays: [
                makeDisplay(displayID: 1, index: 0, capturedAt: capturedAt, lines: lines)
            ]
        )
    }

    private static func makeDisplay(
        displayID: UInt32,
        index: Int,
        capturedAt: Date,
        lines: [ScreenTextLine]
    ) -> DisplayScreenTextDocument {
        DisplayScreenTextDocument(
            displayID: displayID,
            index: index,
            document: ScreenTextDocument(
                capturedAt: capturedAt,
                frameSize: CGSize(width: 200, height: 200),
                frameHash: "frame-\(displayID)-\(capturedAt.timeIntervalSince1970)",
                normalizedTextHash: ScreenTextHasher.hashNormalizedText(lines.map(\.text).joined(separator: "\n")),
                layoutHash: "layout-\(displayID)-\(capturedAt.timeIntervalSince1970)",
                observations: [],
                lines: lines,
                blocks: [],
                regions: []
            )
        )
    }

    private static func makeSnapshot(
        capturedAt: Date,
        displays: [DisplayScreenTextDocument]
    ) -> RealtimeScreenTextSnapshot {
        let document = MultiDisplayScreenTextDocument(
            capturedAt: capturedAt,
            displays: displays
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
            displayCount: displays.count,
            observationCount: document.observationCount,
            lineCount: document.lineCount,
            blockCount: document.blockCount,
            regionCount: document.regionCount,
            aggregateTextHash: ScreenTextHasher.hashAggregateText(document),
            aggregateLayoutHash: ScreenTextHasher.hashAggregateLayout(document),
            displayFrameHashes: displays.map { "frame-\($0.displayID)-\(capturedAt.timeIntervalSince1970)" },
            reusedDisplayCount: 0,
            ocrDisplayCount: displays.count,
            elapsedSeconds: 0
        )
    }
}
#endif
