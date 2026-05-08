# Select Microphone Input Device Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let the user explicitly choose which macOS input device the Microphone transcript pipeline listens to, including virtual cable devices.

**Architecture:** Keep computer audio unchanged through ScreenCaptureKit. Add a Core Audio input-device discovery service, route the selected `AudioDeviceID` through the microphone capture provider, and configure `AVAudioEngine` to use that device before installing its tap. The UI shows a picker near live audio controls and disables device switching while capture is running.

**Tech Stack:** SwiftUI, AVFoundation `AVAudioEngine`, Core Audio `AudioDeviceID`, existing `LiveAudioTranscriptionPipeline`.

---

### File Structure

- Create `falsoai-lens/Pipelines/Hearing/Models/AudioInputDevice.swift`
  - Small `Sendable`, `Identifiable` model for Core Audio input devices.
- Create `falsoai-lens/Pipelines/Hearing/Services/AudioInputDeviceService.swift`
  - Enumerates input-capable Core Audio devices, marks the system default, and formats errors.
- Create `falsoai-lens/Pipelines/Hearing/Services/AudioInputDevicePickerViewModel.swift`
  - Main-actor observable state for device list, selected device, refresh, and error text.
- Modify `falsoai-lens/Pipelines/Hearing/Services/AudioCaptureService.swift`
  - Extend `AudioCaptureConfiguration` with optional `inputDeviceID`.
  - Set `AVAudioEngine.inputNode` to the chosen `AudioDeviceID` before reading format/installing the tap.
- Modify `falsoai-lens/Pipelines/Hearing/Services/LiveAudioCaptureProvider.swift`
  - Add a capture-provider configuration hook for input device selection.
- Modify `falsoai-lens/Pipelines/Hearing/Services/MicrophoneAudioCaptureProvider.swift`
  - Store selected `AudioDeviceID` and pass it into `AudioCaptureService`.
- Modify `falsoai-lens/Pipelines/Hearing/Services/ComputerAudioCaptureService.swift`
  - Implement the new provider hook as a no-op so computer capture stays independent.
- Modify `falsoai-lens/Pipelines/Hearing/Services/LiveAudioTranscriptionPipeline.swift`
  - Add `setInputDeviceID(_:)` to forward UI selection to the microphone provider.
- Modify `falsoai-lens/ContentView.swift`
  - Add the input-device picker and feed its selection into `microphoneHearing`.

---

### Task 1: Add Core Audio Input Device Discovery

**Files:**
- Create: `falsoai-lens/Pipelines/Hearing/Models/AudioInputDevice.swift`
- Create: `falsoai-lens/Pipelines/Hearing/Services/AudioInputDeviceService.swift`

- [ ] **Step 1: Add the input device model**

Create `AudioInputDevice.swift`:

```swift
import CoreAudio
import Foundation

struct AudioInputDevice: Identifiable, Sendable, Equatable {
    let id: AudioDeviceID
    let name: String
    let manufacturer: String?
    let isDefault: Bool

    var displayName: String {
        if let manufacturer, !manufacturer.isEmpty, !name.contains(manufacturer) {
            return "\(name) - \(manufacturer)"
        }
        return name
    }
}
```

- [ ] **Step 2: Add the Core Audio device service**

Create `AudioInputDeviceService.swift`:

```swift
import CoreAudio
import Foundation

enum AudioInputDeviceServiceError: LocalizedError {
    case propertySizeUnavailable(selector: AudioObjectPropertySelector, status: OSStatus)
    case propertyReadFailed(selector: AudioObjectPropertySelector, status: OSStatus)

    var errorDescription: String? {
        switch self {
        case let .propertySizeUnavailable(selector, status):
            return "Could not inspect audio device property \(selector). Core Audio status \(status)."
        case let .propertyReadFailed(selector, status):
            return "Could not read audio device property \(selector). Core Audio status \(status)."
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
```

- [ ] **Step 3: Build to verify the service compiles**

Run:

```bash
xcodebuild -project falsoai-lens.xcodeproj -scheme falsoai-lens -configuration Debug build
```

Expected: build succeeds or fails only on later unimplemented task references if tasks were batched.

---

### Task 2: Configure AVAudioEngine with a Selected Input Device

**Files:**
- Modify: `falsoai-lens/Pipelines/Hearing/Services/AudioCaptureService.swift`

- [ ] **Step 1: Extend the capture configuration**

Change `AudioCaptureConfiguration` to include a selected device:

```swift
struct AudioCaptureConfiguration: Sendable, Equatable {
    var inputBus: AVAudioNodeBus
    var bufferSize: AVAudioFrameCount
    var inputDeviceID: AudioDeviceID?

    nonisolated static let `default` = AudioCaptureConfiguration(
        inputBus: 0,
        bufferSize: 1024,
        inputDeviceID: nil
    )
}
```

- [ ] **Step 2: Add a device-selection error**

Add to `AudioCaptureError`:

```swift
case inputDeviceSelectionFailed(deviceID: AudioDeviceID, status: OSStatus)
```

Add matching `errorDescription`:

```swift
case let .inputDeviceSelectionFailed(deviceID, status):
    return "Could not use audio input device \(deviceID). Core Audio status \(status)."
```

Add matching `recoverySuggestion`:

```swift
case .inputDeviceSelectionFailed:
    return "Choose another microphone or virtual cable input device, then try again."
```

- [ ] **Step 3: Set the selected input device before reading the input format**

In `startCapture(configuration:)`, replace:

```swift
_ = try Self.defaultInputDeviceID()

let inputNode = engine.inputNode
let format = inputNode.outputFormat(forBus: configuration.inputBus)
```

with:

```swift
let deviceID = try configuration.inputDeviceID ?? Self.defaultInputDeviceID()

let inputNode = engine.inputNode
try Self.setInputDevice(deviceID, on: inputNode)
let format = inputNode.outputFormat(forBus: configuration.inputBus)
```

- [ ] **Step 4: Add the Core Audio setter**

Add near `defaultInputDeviceID()`:

```swift
private nonisolated static func setInputDevice(
    _ deviceID: AudioDeviceID,
    on inputNode: AVAudioInputNode
) throws {
    var selectedDeviceID = deviceID
    let status = AudioUnitSetProperty(
        inputNode.audioUnit,
        kAudioOutputUnitProperty_CurrentDevice,
        kAudioUnitScope_Global,
        0,
        &selectedDeviceID,
        UInt32(MemoryLayout<AudioDeviceID>.size)
    )

    guard status == noErr else {
        throw AudioCaptureError.inputDeviceSelectionFailed(
            deviceID: deviceID,
            status: status
        )
    }
}
```

- [ ] **Step 5: Build**

Run:

```bash
xcodebuild -project falsoai-lens.xcodeproj -scheme falsoai-lens -configuration Debug build
```

Expected: build succeeds. If `inputNode.audioUnit` is unavailable on the target SDK, replace this task with an `AudioUnit`-backed input capture implementation; do not fall back to the default input silently.

---

### Task 3: Thread Device Selection Through the Microphone Pipeline

**Files:**
- Modify: `falsoai-lens/Pipelines/Hearing/Services/LiveAudioCaptureProvider.swift`
- Modify: `falsoai-lens/Pipelines/Hearing/Services/MicrophoneAudioCaptureProvider.swift`
- Modify: `falsoai-lens/Pipelines/Hearing/Services/ComputerAudioCaptureService.swift`
- Modify: `falsoai-lens/Pipelines/Hearing/Services/LiveAudioTranscriptionPipeline.swift`

- [ ] **Step 1: Add provider configuration hook**

Change `LiveAudioCaptureProvider` to:

```swift
import CoreAudio
import Foundation

@MainActor
protocol LiveAudioCaptureProvider: AnyObject {
    var isRunning: Bool { get }

    func setInputDeviceID(_ deviceID: AudioDeviceID?)
    func startCapture() async throws -> AsyncStream<CapturedAudioBuffer>
    func stopCapture() async
}
```

- [ ] **Step 2: Store selection in microphone provider**

Update `MicrophoneAudioCaptureProvider`:

```swift
import CoreAudio
import Foundation

@MainActor
final class MicrophoneAudioCaptureProvider: LiveAudioCaptureProvider {
    private let audioCaptureService: AudioCaptureService
    private var inputDeviceID: AudioDeviceID?

    var isRunning: Bool {
        audioCaptureService.isRunning
    }

    init(audioCaptureService: AudioCaptureService? = nil) {
        self.audioCaptureService = audioCaptureService ?? AudioCaptureService()
    }

    func setInputDeviceID(_ deviceID: AudioDeviceID?) {
        guard !isRunning else { return }
        inputDeviceID = deviceID
    }

    func startCapture() async throws -> AsyncStream<CapturedAudioBuffer> {
        var configuration = AudioCaptureConfiguration.default
        configuration.inputDeviceID = inputDeviceID
        return try audioCaptureService.startCapture(configuration: configuration)
    }

    func stopCapture() async {
        audioCaptureService.stopCapture()
    }
}
```

- [ ] **Step 3: Keep computer capture independent**

Add this no-op to `ComputerAudioCaptureService`:

```swift
func setInputDeviceID(_ deviceID: AudioDeviceID?) {
}
```

- [ ] **Step 4: Add pipeline forwarding**

In `LiveAudioTranscriptionPipeline.swift`, import CoreAudio and add:

```swift
func setInputDeviceID(_ deviceID: AudioDeviceID?) {
    guard !isRunning else { return }
    captureProvider.setInputDeviceID(deviceID)

    if source == .microphone {
        statusText = "\(source.displayName) input device selected."
    }
}
```

- [ ] **Step 5: Build**

Run:

```bash
xcodebuild -project falsoai-lens.xcodeproj -scheme falsoai-lens -configuration Debug build
```

Expected: build succeeds.

---

### Task 4: Add the SwiftUI Input Device Picker

**Files:**
- Create: `falsoai-lens/Pipelines/Hearing/Services/AudioInputDevicePickerViewModel.swift`
- Modify: `falsoai-lens/ContentView.swift`

- [ ] **Step 1: Add the picker view model**

Create `AudioInputDevicePickerViewModel.swift`:

```swift
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
            if selectedDeviceID == nil {
                selectedDeviceID = refreshedDevices.first(where: \.isDefault)?.id
            } else if let selectedDeviceID,
                      !refreshedDevices.contains(where: { $0.id == selectedDeviceID }) {
                selectedDeviceID = refreshedDevices.first(where: \.isDefault)?.id
            }
            errorMessage = nil
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}
```

- [ ] **Step 2: Add state to `ContentView`**

Add near the existing `@StateObject` properties:

```swift
@StateObject private var audioInputDevices = AudioInputDevicePickerViewModel()
```

- [ ] **Step 3: Refresh devices when the view loads**

In the existing `.task` block, add:

```swift
audioInputDevices.refresh()
microphoneHearing.setInputDeviceID(audioInputDevices.selectedDeviceID)
```

- [ ] **Step 4: Add the picker near the live controls**

Inside the independent live audio section, before the Start/Clear `HStack`, add:

```swift
HStack {
    Picker("Microphone Input", selection: $audioInputDevices.selectedDeviceID) {
        Text("System Default").tag(AudioDeviceID?.none)
        ForEach(audioInputDevices.devices) { device in
            Text(device.isDefault ? "\(device.displayName) (Default)" : device.displayName)
                .tag(Optional(device.id))
        }
    }
    .frame(maxWidth: 360)
    .disabled(isLiveAudioRunning)
    .onChange(of: audioInputDevices.selectedDeviceID) { _, newValue in
        microphoneHearing.setInputDeviceID(newValue)
    }

    Button {
        audioInputDevices.refresh()
        microphoneHearing.setInputDeviceID(audioInputDevices.selectedDeviceID)
    } label: {
        Label("Refresh Inputs", systemImage: "arrow.clockwise")
    }
    .disabled(isLiveAudioRunning)
}
```

- [ ] **Step 5: Show input picker errors**

Near the existing live audio error messages, add:

```swift
if let inputDeviceError = audioInputDevices.errorMessage {
    Text("Audio inputs: \(inputDeviceError)")
        .font(.callout)
        .foregroundStyle(.red)
        .textSelection(.enabled)
}
```

- [ ] **Step 6: Build**

Run:

```bash
xcodebuild -project falsoai-lens.xcodeproj -scheme falsoai-lens -configuration Debug build
```

Expected: build succeeds.

---

### Task 5: Verify with a Virtual Cable

**Files:**
- Modify only if verification reveals a defect in files touched above.

- [ ] **Step 1: Static verification**

Run:

```bash
rg -n "defaultInputDeviceID\\(\\)" falsoai-lens/Pipelines/Hearing/Services/AudioCaptureService.swift
rg -n "setInputDeviceID|Microphone Input|AudioInputDevice" falsoai-lens
```

Expected:
- `defaultInputDeviceID()` is still present as fallback behavior.
- `setInputDeviceID` appears in provider, pipeline, and UI wiring.
- `Microphone Input` appears in `ContentView.swift`.

- [ ] **Step 2: Build verification**

Run:

```bash
xcodebuild -project falsoai-lens.xcodeproj -scheme falsoai-lens -configuration Debug build
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Manual virtual cable verification**

1. Launch the app from Xcode.
2. In the new **Microphone Input** picker, choose the virtual cable device.
3. Route audio into the virtual cable.
4. Start capture.
5. Confirm the **Microphone** panel shows only the audio routed into the virtual cable.
6. Confirm the **Computer Audio** panel still uses ScreenCaptureKit and does not depend on the selected microphone input.
7. Stop capture, choose a real microphone, start capture again, and confirm the Microphone panel switches to that device.

Expected: switching the picker before capture changes the microphone source; switching is disabled during capture to avoid Core Audio device churn.

---

### Self-Review Notes

- Spec coverage: This plan makes the virtual cable work by selecting it explicitly as the Microphone input. It does not route system audio into the cable; routing remains the user's responsibility in their virtual cable app.
- Architecture check: Computer audio capture stays independent. Microphone capture gets only one selected Core Audio input device.
- Risk: `AVAudioEngine` input-device selection depends on `AVAudioInputNode.audioUnit` availability on this macOS SDK. The plan calls out the fallback requirement if that API is unavailable: implement an `AudioUnit` input provider rather than silently reverting to default input.
