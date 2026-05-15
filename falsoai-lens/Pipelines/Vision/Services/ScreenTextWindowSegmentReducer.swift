import CoreGraphics
import Foundation

struct ScreenTextWindowSegmentReducer: Sendable {
    private static let chromeCapableRoles: Set<ScreenTextStructureRole> = [
        .navigation,
        .buttonLike,
        .linkLike,
        .formLabel,
        .tableHeader,
        .chrome
    ]

    func reduce(_ window: ScreenTextWindow) -> [ScreenTextWindowSegment] {
        guard !window.encounters.isEmpty else { return [] }

        let groups = Dictionary(grouping: window.encounters) { encounter in
            SegmentKey(displayID: encounter.displayID, role: encounter.dominantRole)
        }

        let sortedKeys = groups.keys.sorted { lhs, rhs in
            if lhs.displayID != rhs.displayID {
                return lhs.displayID < rhs.displayID
            }
            return lhs.role.rawValue < rhs.role.rawValue
        }

        return sortedKeys.map { key in
            let encounters = groups[key] ?? []
            return makeSegment(
                key: key,
                encounters: encounters,
                windowSeconds: window.durationSeconds
            )
        }
    }

    private func makeSegment(
        key: SegmentKey,
        encounters: [ScreenTextEncounter],
        windowSeconds: TimeInterval
    ) -> ScreenTextWindowSegment {
        let sortedEncounters = encounters.sorted { lhs, rhs in
            let lhsY = lhs.latestSighting?.bounds.minY ?? 0
            let rhsY = rhs.latestSighting?.bounds.minY ?? 0
            if lhsY != rhsY {
                return lhsY < rhsY
            }
            let lhsX = lhs.latestSighting?.bounds.minX ?? 0
            let rhsX = rhs.latestSighting?.bounds.minX ?? 0
            return lhsX < rhsX
        }

        let text = sortedEncounters.map(\.text).joined(separator: " ")

        let boundsUnion = sortedEncounters
            .compactMap { $0.latestSighting?.bounds }
            .reduce(CGRect.null) { partialResult, rect in
                partialResult.isNull ? rect : partialResult.union(rect)
            }

        let firstSightedAt = sortedEncounters.map(\.firstSeenAt).min() ?? Date()
        let lastSightedAt = sortedEncounters.map(\.lastSeenAt).max() ?? Date()
        let totalSightingCount = sortedEncounters.reduce(0) { $0 + $1.seenCount }
        let lineCount = sortedEncounters.count

        let displayIndex = sortedEncounters.first?.displayIndex ?? 0

        return ScreenTextWindowSegment(
            id: "d\(key.displayID).\(key.role.rawValue)",
            displayID: key.displayID,
            displayIndex: displayIndex,
            role: key.role,
            boundsUnion: boundsUnion.isNull ? .zero : boundsUnion,
            text: text,
            lineCount: lineCount,
            totalSightingCount: totalSightingCount,
            firstSightedAt: firstSightedAt,
            lastSightedAt: lastSightedAt,
            isRepeatedUI: Self.isRepeatedUI(
                role: key.role,
                totalSightingCount: totalSightingCount,
                lineCount: lineCount,
                windowSeconds: windowSeconds
            )
        )
    }

    private static func isRepeatedUI(
        role: ScreenTextStructureRole,
        totalSightingCount: Int,
        lineCount: Int,
        windowSeconds: TimeInterval
    ) -> Bool {
        guard chromeCapableRoles.contains(role) else { return false }
        guard lineCount > 0, windowSeconds > 0 else { return false }

        let sightingsPerLinePerSecond = Double(totalSightingCount) / Double(lineCount) / windowSeconds
        return sightingsPerLinePerSecond >= 0.5
    }

    private struct SegmentKey: Hashable, Sendable {
        let displayID: UInt32
        let role: ScreenTextStructureRole
    }
}

#if DEBUG
extension ScreenTextWindowSegmentReducer {
    static func runSmokeChecks() {
        verifySegmentsGroupByDisplayAndRole()
        verifyRepeatedNavigationFlagsAsChrome()
        verifyEmptyWindowProducesNoSegments()
    }

    private static func makeEncounter(
        text: String,
        displayID: UInt32,
        displayIndex: Int = 0,
        role: ScreenTextStructureRole,
        seenCount: Int = 1,
        firstSeenAt: Date = Date(timeIntervalSince1970: 0),
        lastSeenAt: Date = Date(timeIntervalSince1970: 10),
        boundsY: CGFloat = 0
    ) -> ScreenTextEncounter {
        let bounds = CGRect(x: 0, y: boundsY, width: 100, height: 20)
        let sighting = ScreenTextEncounterSighting(
            bounds: bounds,
            sightedAt: lastSeenAt,
            role: role,
            blockAlias: nil
        )
        return ScreenTextEncounter(
            text: text,
            normalizedTextHash: "hash-\(text)",
            displayID: displayID,
            displayIndex: displayIndex,
            firstSeenAt: firstSeenAt,
            lastSeenAt: lastSeenAt,
            seenCount: seenCount,
            sightings: [sighting],
            roleCounts: [role: seenCount]
        )
    }

    private static func makeWindow(
        encounters: [ScreenTextEncounter],
        durationSeconds: TimeInterval = 60
    ) -> ScreenTextWindow {
        ScreenTextWindow(
            id: UUID(),
            sessionID: UUID(),
            sequenceNumber: 1,
            startedAt: Date(timeIntervalSince1970: 0),
            endedAt: Date(timeIntervalSince1970: durationSeconds),
            encounters: encounters
        )
    }

    private static func verifySegmentsGroupByDisplayAndRole() {
        let reducer = ScreenTextWindowSegmentReducer()
        let window = makeWindow(encounters: [
            makeEncounter(text: "Article body alpha", displayID: 1, role: .paragraph, boundsY: 100),
            makeEncounter(text: "Article body bravo", displayID: 1, role: .paragraph, boundsY: 150),
            makeEncounter(text: "Home", displayID: 1, role: .navigation, boundsY: 0),
            makeEncounter(text: "Editor pane code", displayID: 2, role: .codeOrLog, boundsY: 50)
        ])

        let segments = reducer.reduce(window)
        assert(segments.count == 3,
               "Expected three segments (two displays × roles present), got \(segments.count)")

        let paragraph = segments.first { $0.displayID == 1 && $0.role == .paragraph }
        assert(paragraph?.text == "Article body alpha Article body bravo",
               "Expected paragraphs concatenated in reading order, got \(paragraph?.text ?? "nil")")

        let codeSegment = segments.first { $0.displayID == 2 && $0.role == .codeOrLog }
        assert(codeSegment?.displayIndex == 0,
               "Expected code segment to carry displayIndex from its encounter")
    }

    private static func verifyRepeatedNavigationFlagsAsChrome() {
        let reducer = ScreenTextWindowSegmentReducer()
        let window = makeWindow(encounters: [
            makeEncounter(text: "Home", displayID: 1, role: .navigation, seenCount: 60),
            makeEncounter(text: "Search", displayID: 1, role: .navigation, seenCount: 60),
            makeEncounter(text: "Article one", displayID: 1, role: .paragraph, seenCount: 2)
        ])

        let segments = reducer.reduce(window)
        let nav = segments.first { $0.role == .navigation }
        let paragraph = segments.first { $0.role == .paragraph }

        assert(nav?.isRepeatedUI == true,
               "Expected repeated navigation to flag isRepeatedUI")
        assert(paragraph?.isRepeatedUI == false,
               "Expected non-repeating paragraph not to flag isRepeatedUI")
    }

    private static func verifyEmptyWindowProducesNoSegments() {
        let reducer = ScreenTextWindowSegmentReducer()
        let window = makeWindow(encounters: [])
        assert(reducer.reduce(window).isEmpty, "Expected empty window to produce no segments")
    }
}
#endif
