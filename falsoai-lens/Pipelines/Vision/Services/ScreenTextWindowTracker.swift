import Foundation

struct ScreenTextWindowTracker: Sendable {
    let windowSeconds: TimeInterval
    private(set) var currentWindowStartedAt: Date?

    init(windowSeconds: TimeInterval = 5 * 60) {
        self.windowSeconds = max(1, windowSeconds)
    }

    mutating func start(referenceDate: Date) {
        currentWindowStartedAt = referenceDate
    }

    mutating func sealIfElapsed(referenceDate: Date) -> ScreenTextWindowInterval? {
        guard let started = currentWindowStartedAt else { return nil }
        guard referenceDate.timeIntervalSince(started) >= windowSeconds else { return nil }

        let interval = ScreenTextWindowInterval(startedAt: started, endedAt: referenceDate)
        currentWindowStartedAt = referenceDate
        return interval
    }

    mutating func stop() {
        currentWindowStartedAt = nil
    }
}

#if DEBUG
extension ScreenTextWindowTracker {
    static func runSmokeChecks() {
        verifyDoesNotSealBeforeWindowElapses()
        verifySealsExactlyAtWindowBoundary()
        verifySealsAndContinuesIntoNextWindow()
        verifyStopClearsState()
        verifyDoesNotSealWithoutStart()
    }

    private static func verifyDoesNotSealBeforeWindowElapses() {
        var tracker = ScreenTextWindowTracker(windowSeconds: 60)
        let t0 = Date(timeIntervalSince1970: 1_000)
        tracker.start(referenceDate: t0)
        let result = tracker.sealIfElapsed(referenceDate: t0.addingTimeInterval(59))
        assert(result == nil, "Tracker sealed before windowSeconds elapsed")
        assert(tracker.currentWindowStartedAt == t0, "Tracker dropped its anchor without sealing")
    }

    private static func verifySealsExactlyAtWindowBoundary() {
        var tracker = ScreenTextWindowTracker(windowSeconds: 60)
        let t0 = Date(timeIntervalSince1970: 2_000)
        tracker.start(referenceDate: t0)
        let result = tracker.sealIfElapsed(referenceDate: t0.addingTimeInterval(60))
        assert(result == ScreenTextWindowInterval(startedAt: t0, endedAt: t0.addingTimeInterval(60)),
               "Tracker did not seal at the window boundary")
        assert(tracker.currentWindowStartedAt == t0.addingTimeInterval(60),
               "Tracker did not reset its anchor to the seal time")
    }

    private static func verifySealsAndContinuesIntoNextWindow() {
        var tracker = ScreenTextWindowTracker(windowSeconds: 60)
        let t0 = Date(timeIntervalSince1970: 3_000)
        tracker.start(referenceDate: t0)
        _ = tracker.sealIfElapsed(referenceDate: t0.addingTimeInterval(60))
        let secondResult = tracker.sealIfElapsed(referenceDate: t0.addingTimeInterval(119))
        assert(secondResult == nil, "Tracker sealed second window before its boundary")

        let thirdResult = tracker.sealIfElapsed(referenceDate: t0.addingTimeInterval(120))
        assert(thirdResult == ScreenTextWindowInterval(
                startedAt: t0.addingTimeInterval(60),
                endedAt: t0.addingTimeInterval(120)),
               "Tracker did not seal the second window correctly")
    }

    private static func verifyStopClearsState() {
        var tracker = ScreenTextWindowTracker(windowSeconds: 60)
        tracker.start(referenceDate: Date())
        tracker.stop()
        assert(tracker.currentWindowStartedAt == nil, "Tracker.stop did not clear state")
        let result = tracker.sealIfElapsed(referenceDate: Date().addingTimeInterval(120))
        assert(result == nil, "Tracker sealed after stop")
    }

    private static func verifyDoesNotSealWithoutStart() {
        var tracker = ScreenTextWindowTracker(windowSeconds: 60)
        let result = tracker.sealIfElapsed(referenceDate: Date())
        assert(result == nil, "Tracker sealed without ever starting")
    }
}
#endif
