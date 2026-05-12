import Foundation

struct ScreenTextWindowInterval: Equatable, Sendable {
    let startedAt: Date
    let endedAt: Date

    var durationSeconds: TimeInterval {
        endedAt.timeIntervalSince(startedAt)
    }
}
