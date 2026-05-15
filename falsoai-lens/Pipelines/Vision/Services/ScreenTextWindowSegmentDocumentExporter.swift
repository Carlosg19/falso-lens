import CoreGraphics
import Foundation

struct ScreenTextWindowSegmentDocumentExporter: Sendable {
    private let reducer: ScreenTextWindowSegmentReducer

    init(reducer: ScreenTextWindowSegmentReducer = ScreenTextWindowSegmentReducer()) {
        self.reducer = reducer
    }

    func export(_ window: ScreenTextWindow) -> ScreenTextWindowSegmentDocument {
        let segments = reducer.reduce(window)
        let displayCount = Set(window.encounters.map(\.displayID)).count

        let metadata = ScreenTextWindowMetadataDTO(
            id: window.id,
            sessionID: window.sessionID,
            sequenceNumber: window.sequenceNumber,
            startedAt: window.startedAt,
            endedAt: window.endedAt,
            durationSeconds: window.durationSeconds,
            displayCount: displayCount,
            encounterCount: window.encounterCount,
            segmentCount: segments.count
        )

        let segmentDTOs = segments.map(makeSegmentDTO(from:))

        return ScreenTextWindowSegmentDocument(
            window: metadata,
            segments: segmentDTOs
        )
    }

    func compactJSON(_ document: ScreenTextWindowSegmentDocument) throws -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(document)
        return String(decoding: data, as: UTF8.self)
    }

    private func makeSegmentDTO(from segment: ScreenTextWindowSegment) -> ScreenTextWindowSegmentDTO {
        ScreenTextWindowSegmentDTO(
            id: segment.id,
            displayID: segment.displayID,
            displayIndex: segment.displayIndex,
            role: segment.role,
            bounds: ScreenTextWindowBoundsDTO(segment.boundsUnion),
            text: segment.text,
            lineCount: segment.lineCount,
            totalSightingCount: segment.totalSightingCount,
            firstSightedAt: segment.firstSightedAt,
            lastSightedAt: segment.lastSightedAt,
            isRepeatedUI: segment.isRepeatedUI
        )
    }
}

#if DEBUG
extension ScreenTextWindowSegmentDocumentExporter {
    static func runSmokeChecks() throws {
        try verifyEmptyWindowProducesEmptySegments()
        try verifyNonEmptyWindowRoundTripsThroughJSON()
        try verifyMetadataCountsMatchTheWindow()
    }

    private static func makeEncounter(
        text: String,
        displayID: UInt32,
        role: ScreenTextStructureRole,
        seenCount: Int = 1
    ) -> ScreenTextEncounter {
        let firstSeen = Date(timeIntervalSince1970: 0)
        let lastSeen = Date(timeIntervalSince1970: 10)
        let bounds = CGRect(x: 0, y: 0, width: 100, height: 20)
        return ScreenTextEncounter(
            text: text,
            normalizedTextHash: "hash-\(text)-\(displayID)",
            displayID: displayID,
            displayIndex: Int(displayID) - 1,
            firstSeenAt: firstSeen,
            lastSeenAt: lastSeen,
            seenCount: seenCount,
            sightings: [
                ScreenTextEncounterSighting(
                    bounds: bounds,
                    sightedAt: lastSeen,
                    role: role,
                    blockAlias: nil
                )
            ],
            roleCounts: [role: seenCount]
        )
    }

    private static func makeWindow(encounters: [ScreenTextEncounter]) -> ScreenTextWindow {
        ScreenTextWindow(
            id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            sessionID: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
            sequenceNumber: 1,
            startedAt: Date(timeIntervalSince1970: 0),
            endedAt: Date(timeIntervalSince1970: 60),
            encounters: encounters
        )
    }

    private static func verifyEmptyWindowProducesEmptySegments() throws {
        let exporter = ScreenTextWindowSegmentDocumentExporter()
        let window = makeWindow(encounters: [])
        let document = exporter.export(window)

        assert(document.segments.isEmpty, "Expected empty window to produce zero segments")
        assert(document.window.segmentCount == 0, "Expected segmentCount to match segments.count")
        assert(document.window.displayCount == 0, "Expected displayCount to be 0 for empty window")
        assert(document.window.encounterCount == 0, "Expected encounterCount to be 0 for empty window")

        let json = try exporter.compactJSON(document)
        assert(json.contains("\"segments\":[]"), "Expected empty segments array in JSON")
    }

    private static func verifyNonEmptyWindowRoundTripsThroughJSON() throws {
        let exporter = ScreenTextWindowSegmentDocumentExporter()
        let window = makeWindow(encounters: [
            makeEncounter(text: "Hello", displayID: 1, role: .heading),
            makeEncounter(text: "World", displayID: 2, role: .paragraph)
        ])
        let document = exporter.export(window)
        let json = try exporter.compactJSON(document)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(ScreenTextWindowSegmentDocument.self, from: Data(json.utf8))

        assert(decoded == document, "Expected JSON round-trip to preserve the document")
    }

    private static func verifyMetadataCountsMatchTheWindow() throws {
        let exporter = ScreenTextWindowSegmentDocumentExporter()
        let window = makeWindow(encounters: [
            makeEncounter(text: "A", displayID: 1, role: .paragraph),
            makeEncounter(text: "B", displayID: 1, role: .paragraph),
            makeEncounter(text: "C", displayID: 2, role: .navigation)
        ])
        let document = exporter.export(window)

        assert(document.window.encounterCount == 3,
               "Expected encounterCount to mirror window.encounters.count, got \(document.window.encounterCount)")
        assert(document.window.displayCount == 2,
               "Expected displayCount to count unique displayIDs, got \(document.window.displayCount)")
        assert(document.window.segmentCount == document.segments.count,
               "Expected segmentCount to match segments.count")
    }
}
#endif
