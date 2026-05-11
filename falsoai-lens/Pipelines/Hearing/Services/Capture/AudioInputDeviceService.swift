import AVFoundation
import CoreAudio
import Foundation

enum AudioInputDeviceServiceError: LocalizedError {
    case propertySizeUnavailable(selector: AudioObjectPropertySelector, status: OSStatus)
    case propertyReadFailed(selector: AudioObjectPropertySelector, status: OSStatus)
    case invalidInputFormat(deviceID: AudioDeviceID, sampleRate: Double, channelCount: Int)

    var errorDescription: String? {
        switch self {
        case let .propertySizeUnavailable(selector, status):
            return "Could not inspect audio device property \(selector). Core Audio status \(status)."
        case let .propertyReadFailed(selector, status):
            return "Could not read audio device property \(selector). Core Audio status \(status)."
        case let .invalidInputFormat(deviceID, sampleRate, channelCount):
            return "Audio input device \(deviceID) reported an invalid capture format: \(sampleRate) Hz / \(channelCount) channels."
        }
    }
}

enum AudioInputDeviceService {
    nonisolated static func availableInputDevices() throws -> [AudioInputDevice] {
        let defaultID = try defaultInputDeviceID()
        let deviceIDs = try allAudioDeviceIDs()

        return try deviceIDs
            .filter { try inputChannelCount(for: $0) > 0 }
            .map { deviceID in
                AudioInputDevice(
                    id: deviceID,
                    name: try stringProperty(kAudioObjectPropertyName, for: deviceID) ?? "Input \(deviceID)",
                    manufacturer: try stringProperty(kAudioObjectPropertyManufacturer, for: deviceID),
                    isDefault: deviceID == defaultID
                )
            }
            .sorted { lhs, rhs in
                if lhs.isDefault != rhs.isDefault { return lhs.isDefault }
                return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
            }
    }

    nonisolated static func defaultInputDeviceID() throws -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioDeviceID(kAudioObjectUnknown)
        var dataSize = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &dataSize,
            &deviceID
        )

        guard status == noErr else {
            throw AudioInputDeviceServiceError.propertyReadFailed(
                selector: kAudioHardwarePropertyDefaultInputDevice,
                status: status
            )
        }

        return deviceID == kAudioObjectUnknown ? nil : deviceID
    }

    nonisolated static func displayName(for deviceID: AudioDeviceID) throws -> String {
        let name = try stringProperty(kAudioObjectPropertyName, for: deviceID) ?? "Input \(deviceID)"
        let manufacturer = try stringProperty(kAudioObjectPropertyManufacturer, for: deviceID)
        return AudioInputDevice(
            id: deviceID,
            name: name,
            manufacturer: manufacturer,
            isDefault: false
        ).displayName
    }

    nonisolated static func inputFormat(for deviceID: AudioDeviceID) throws -> AVAudioFormat {
        let sampleRate = try nominalSampleRate(for: deviceID)
        let channelCount = try inputChannelCount(for: deviceID)

        guard sampleRate > 0,
              channelCount > 0,
              let format = AVAudioFormat(
                standardFormatWithSampleRate: sampleRate,
                channels: AVAudioChannelCount(channelCount)
              )
        else {
            throw AudioInputDeviceServiceError.invalidInputFormat(
                deviceID: deviceID,
                sampleRate: sampleRate,
                channelCount: channelCount
            )
        }

        return format
    }

    private nonisolated static func allAudioDeviceIDs() throws -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &dataSize
        )
        guard status == noErr else {
            throw AudioInputDeviceServiceError.propertySizeUnavailable(
                selector: kAudioHardwarePropertyDevices,
                status: status
            )
        }

        let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var devices = Array(repeating: AudioDeviceID(kAudioObjectUnknown), count: count)
        status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &dataSize,
            &devices
        )
        guard status == noErr else {
            throw AudioInputDeviceServiceError.propertyReadFailed(
                selector: kAudioHardwarePropertyDevices,
                status: status
            )
        }

        return devices.filter { $0 != kAudioObjectUnknown }
    }

    private nonisolated static func inputChannelCount(for deviceID: AudioDeviceID) throws -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &dataSize)
        guard status == noErr, dataSize > 0 else { return 0 }

        let maximumBuffers = max(1, Int(dataSize) / MemoryLayout<AudioBuffer>.stride)
        let bufferList = AudioBufferList.allocate(maximumBuffers: maximumBuffers)
        defer { bufferList.unsafeMutablePointer.deallocate() }

        status = AudioObjectGetPropertyData(
            deviceID,
            &address,
            0,
            nil,
            &dataSize,
            bufferList.unsafeMutablePointer
        )
        guard status == noErr else {
            throw AudioInputDeviceServiceError.propertyReadFailed(
                selector: kAudioDevicePropertyStreamConfiguration,
                status: status
            )
        }

        return bufferList.reduce(0) { partialResult, buffer in
            partialResult + Int(buffer.mNumberChannels)
        }
    }

    private nonisolated static func nominalSampleRate(for deviceID: AudioDeviceID) throws -> Double {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var sampleRate = Float64(0)
        var dataSize = UInt32(MemoryLayout<Float64>.size)
        let status = AudioObjectGetPropertyData(
            deviceID,
            &address,
            0,
            nil,
            &dataSize,
            &sampleRate
        )

        guard status == noErr else {
            throw AudioInputDeviceServiceError.propertyReadFailed(
                selector: kAudioDevicePropertyNominalSampleRate,
                status: status
            )
        }

        return sampleRate
    }

    private nonisolated static func stringProperty(
        _ selector: AudioObjectPropertySelector,
        for deviceID: AudioDeviceID
    ) throws -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: CFString = "" as CFString
        var dataSize = UInt32(MemoryLayout<CFString>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, &value)
        guard status == noErr else { return nil }
        return value as String
    }
}
