import Combine
import CoreAudio
import Foundation

@MainActor
final class AudioInputDevicePickerViewModel: ObservableObject {
    @Published private(set) var devices: [AudioInputDevice] = []
    @Published var selectedDeviceID: AudioDeviceID?
    @Published private(set) var errorMessage: String?

    var selectedDeviceName: String {
        guard let selectedDeviceID,
              let device = devices.first(where: { $0.id == selectedDeviceID })
        else {
            return "System Default"
        }
        return device.displayName
    }

    func refresh() {
        do {
            let refreshedDevices = try AudioInputDeviceService.availableInputDevices()
            devices = refreshedDevices
            if let selectedDeviceID,
               !refreshedDevices.contains(where: { $0.id == selectedDeviceID }) {
                self.selectedDeviceID = nil
            }
            errorMessage = nil
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}
