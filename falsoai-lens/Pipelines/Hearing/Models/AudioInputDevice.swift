import CoreAudio
import Foundation

struct AudioInputDevice: Identifiable, Sendable, Equatable {
    let id: AudioDeviceID
    let name: String
    let manufacturer: String?
    let isDefault: Bool

    nonisolated var displayName: String {
        if let manufacturer, !manufacturer.isEmpty, !name.contains(manufacturer) {
            return "\(name) - \(manufacturer)"
        }
        return name
    }
}
