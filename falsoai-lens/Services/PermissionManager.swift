import Foundation
import AVFoundation
import ApplicationServices
import CoreGraphics
import OSLog
import Security
import UserNotifications

enum PermissionStatus: Equatable {
    case authorized
    case denied
    case notDetermined
    case restricted
    case unknown
}

struct PermissionSnapshot: Equatable {
    let screenRecording: PermissionStatus
    let accessibility: PermissionStatus
    let notifications: PermissionStatus
    let microphone: PermissionStatus
}

struct RuntimePermissionIdentity: Equatable {
    let bundleIdentifier: String
    let bundlePath: String
    let executablePath: String
    let processIdentifier: Int32
    let processName: String
    let isRunningForPreviews: Bool
    let signingIdentifier: String
    let signingTeamIdentifier: String
    let signingFlags: String
    let designatedRequirement: String
    let entitlementKeys: [String]
    let screenRecordingDiagnosis: String
    let tccResetCommand: String
    let tccResetAllCommand: String

    var summary: String {
        [
            "Bundle: \(bundleIdentifier)",
            "PID: \(processIdentifier)",
            "Process: \(processName)",
            "Previews: \(isRunningForPreviews)",
            "Signing ID: \(signingIdentifier)",
            "Team: \(signingTeamIdentifier)",
            "Flags: \(signingFlags)",
            "App: \(bundlePath)",
            "Exec: \(executablePath)"
        ].joined(separator: " | ")
    }

    var expandedSummary: String {
        [
            summary,
            "Requirement: \(designatedRequirement)",
            "Entitlements: \(entitlementKeys.isEmpty ? "none" : entitlementKeys.joined(separator: ", "))",
            "Screen Recording diagnosis: \(screenRecordingDiagnosis)",
            "Reset bundle: \(tccResetCommand)",
            "Reset all: \(tccResetAllCommand)"
        ].joined(separator: " | ")
    }
}

@MainActor
final class PermissionManager {
    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.falsoai.FalsoaiLens",
        category: "Permissions"
    )

    func currentSnapshot() async -> PermissionSnapshot {
        logger.info("Collecting permission snapshot")
        logRuntimeIdentity()
        let notificationSettings = await UNUserNotificationCenter.current().notificationSettings()
        logger.info("UNUserNotificationCenter authorization raw=\(notificationSettings.authorizationStatus.rawValue, privacy: .public), alert=\(notificationSettings.alertSetting.rawValue, privacy: .public), sound=\(notificationSettings.soundSetting.rawValue, privacy: .public), badge=\(notificationSettings.badgeSetting.rawValue, privacy: .public)")
        let snapshot = PermissionSnapshot(
            screenRecording: screenRecordingStatus(),
            accessibility: accessibilityStatus(prompt: false),
            notifications: Self.notificationStatus(from: notificationSettings.authorizationStatus),
            microphone: microphoneStatus()
        )

        logger.info("Permission snapshot screen=\(String(describing: snapshot.screenRecording), privacy: .public), accessibility=\(String(describing: snapshot.accessibility), privacy: .public), notifications=\(String(describing: snapshot.notifications), privacy: .public), microphone=\(String(describing: snapshot.microphone), privacy: .public)")
        return snapshot
    }

    func runtimeIdentity() -> RuntimePermissionIdentity {
        let bundleIdentifier = Bundle.main.bundleIdentifier ?? "unknown"
        let bundlePath = Bundle.main.bundlePath
        let executablePath = Bundle.main.executablePath ?? "unknown"
        let processInfo = ProcessInfo.processInfo
        let environment = processInfo.environment
        let signingInfo = Self.currentSigningInfo()

        return RuntimePermissionIdentity(
            bundleIdentifier: bundleIdentifier,
            bundlePath: bundlePath,
            executablePath: executablePath,
            processIdentifier: processInfo.processIdentifier,
            processName: processInfo.processName,
            isRunningForPreviews: environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1",
            signingIdentifier: signingInfo.identifier,
            signingTeamIdentifier: signingInfo.teamIdentifier,
            signingFlags: signingInfo.flags,
            designatedRequirement: signingInfo.designatedRequirement,
            entitlementKeys: signingInfo.entitlementKeys,
            screenRecordingDiagnosis: Self.screenRecordingDiagnosis(
                teamIdentifier: signingInfo.teamIdentifier,
                designatedRequirement: signingInfo.designatedRequirement,
                bundlePath: bundlePath
            ),
            tccResetCommand: "tccutil reset ScreenCapture \(bundleIdentifier)",
            tccResetAllCommand: "tccutil reset ScreenCapture"
        )
    }

    func screenRecordingStatus() -> PermissionStatus {
        logger.info("Checking CGPreflightScreenCaptureAccess for bundle=\(Bundle.main.bundleIdentifier ?? "unknown", privacy: .public), executable=\(Bundle.main.executablePath ?? "unknown", privacy: .public)")
        let isAuthorized = CGPreflightScreenCaptureAccess()
        logger.info("CGPreflightScreenCaptureAccess returned \(isAuthorized, privacy: .public)")
        return isAuthorized ? .authorized : .notDetermined
    }

    @discardableResult
    func requestScreenRecordingPermission() -> Bool {
        logger.info("Calling CGRequestScreenCaptureAccess")
        logRuntimeIdentity()
        let before = CGPreflightScreenCaptureAccess()
        logger.info("Pre-request CGPreflightScreenCaptureAccess returned \(before, privacy: .public)")
        let isAuthorized = CGRequestScreenCaptureAccess()
        logger.info("CGRequestScreenCaptureAccess returned \(isAuthorized, privacy: .public)")
        let after = CGPreflightScreenCaptureAccess()
        logger.info("Post-request CGPreflightScreenCaptureAccess returned \(after, privacy: .public)")
        return isAuthorized
    }

    func accessibilityStatus(prompt: Bool) -> PermissionStatus {
        logger.info("Checking accessibility permission prompt=\(prompt, privacy: .public)")
        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options = [promptKey: prompt] as CFDictionary
        let isAuthorized = AXIsProcessTrustedWithOptions(options)
        logger.info("AXIsProcessTrustedWithOptions returned \(isAuthorized, privacy: .public)")
        return isAuthorized ? .authorized : .notDetermined
    }

    func microphoneStatus() -> PermissionStatus {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        logger.info("AVCaptureDevice audio authorization status raw=\(status.rawValue, privacy: .public)")

        switch status {
        case .authorized:
            return .authorized
        case .denied:
            return .denied
        case .notDetermined:
            return .notDetermined
        case .restricted:
            return .restricted
        @unknown default:
            return .unknown
        }
    }

    func requestMicrophoneAccess() async -> Bool {
        logger.info("Calling AVCaptureDevice.requestAccess for microphone")
        return await withCheckedContinuation { continuation in
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                Logger(
                    subsystem: Bundle.main.bundleIdentifier ?? "com.falsoai.FalsoaiLens",
                    category: "Permissions"
                ).info("AVCaptureDevice.requestAccess microphone returned \(granted, privacy: .public)")
                continuation.resume(returning: granted)
            }
        }
    }

    private static func notificationStatus(from status: UNAuthorizationStatus) -> PermissionStatus {
        switch status {
        case .authorized, .provisional:
            return .authorized
        case .denied:
            return .denied
        case .notDetermined:
            return .notDetermined
        @unknown default:
            return .unknown
        }
    }

    private func logRuntimeIdentity() {
        let identity = runtimeIdentity()
        logger.info("Runtime identity \(identity.expandedSummary, privacy: .public)")
        logger.info("Bundle metadata \(Self.bundleMetadataSummary(), privacy: .public)")
        logger.info("Environment metadata \(Self.environmentSummary(), privacy: .public)")
        logger.warning("Screen Recording diagnosis: \(identity.screenRecordingDiagnosis, privacy: .public)")
        logger.info("TCC reset command: \(identity.tccResetCommand, privacy: .public)")
        logger.info("TCC reset all command: \(identity.tccResetAllCommand, privacy: .public)")
    }

    private static func bundleMetadataSummary() -> String {
        let bundle = Bundle.main
        let info = bundle.infoDictionary ?? [:]
        let keys = [
            "CFBundleName",
            "CFBundleDisplayName",
            "CFBundleExecutable",
            "CFBundleIdentifier",
            "CFBundleVersion",
            "CFBundleShortVersionString",
            "LSMinimumSystemVersion",
            "NSMicrophoneUsageDescription"
        ]

        return keys.map { key in
            "\(key)=\(info[key] ?? "nil")"
        }.joined(separator: " | ")
    }

    private static func environmentSummary() -> String {
        let environment = ProcessInfo.processInfo.environment
        let keys = [
            "XCODE_RUNNING_FOR_PREVIEWS",
            "__CFBundleIdentifier",
            "XPC_SERVICE_NAME",
            "CODESIGNING_FOLDER_PATH",
            "DYLD_INSERT_LIBRARIES"
        ]

        return keys.map { key in
            "\(key)=\(environment[key] ?? "nil")"
        }.joined(separator: " | ")
    }

    private static func screenRecordingDiagnosis(
        teamIdentifier: String,
        designatedRequirement: String,
        bundlePath: String
    ) -> String {
        if teamIdentifier == "none" || designatedRequirement.hasPrefix("cdhash ") {
            return "Ad-hoc/cdhash-only signing detected. Screen Recording permission can fail or become stale for Xcode DerivedData builds. Use stable Apple Development signing, then reset ScreenCapture permission and grant it again."
        }

        if bundlePath.contains("/DerivedData/") {
            return "Running from Xcode DerivedData. If permission was granted to another app copy, reset ScreenCapture permission and grant this exact build."
        }

        return "Stable signing identity detected. If access still fails, reset ScreenCapture permission, quit the app, grant permission again, then reopen."
    }

    private static func currentSigningInfo() -> (
        identifier: String,
        teamIdentifier: String,
        flags: String,
        designatedRequirement: String,
        entitlementKeys: [String]
    ) {
        var code: SecCode?
        let codeStatus = SecCodeCopySelf(SecCSFlags(), &code)

        guard codeStatus == errSecSuccess, let code else {
            return ("unavailable(\(codeStatus))", "unavailable", "unavailable", "unavailable", [])
        }

        var staticCode: SecStaticCode?
        let staticCodeStatus = SecCodeCopyStaticCode(code, SecCSFlags(), &staticCode)

        guard staticCodeStatus == errSecSuccess, let staticCode else {
            return ("unavailable(\(staticCodeStatus))", "unavailable", "unavailable", "unavailable", [])
        }

        var information: CFDictionary?
        let infoStatus = SecCodeCopySigningInformation(
            staticCode,
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &information
        )

        guard infoStatus == errSecSuccess,
              let info = information as? [String: Any] else {
            return ("unavailable(\(infoStatus))", "unavailable", "unavailable", "unavailable", [])
        }

        let identifier = info[kSecCodeInfoIdentifier as String] as? String ?? "unknown"
        let teamIdentifier = info[kSecCodeInfoTeamIdentifier as String] as? String ?? "none"
        let flagsValue = info[kSecCodeInfoFlags as String].map { "\($0)" } ?? "unknown"
        let entitlementKeys = (info[kSecCodeInfoEntitlementsDict as String] as? [String: Any])?
            .keys
            .sorted() ?? []
        let designatedRequirement = Self.designatedRequirement(for: staticCode)

        return (identifier, teamIdentifier, flagsValue, designatedRequirement, entitlementKeys)
    }

    private static func designatedRequirement(for staticCode: SecStaticCode) -> String {
        var requirement: SecRequirement?
        let requirementStatus = SecCodeCopyDesignatedRequirement(
            staticCode,
            SecCSFlags(),
            &requirement
        )

        guard requirementStatus == errSecSuccess, let requirement else {
            return "unavailable(\(requirementStatus))"
        }

        var requirementString: CFString?
        let stringStatus = SecRequirementCopyString(
            requirement,
            SecCSFlags(),
            &requirementString
        )

        guard stringStatus == errSecSuccess, let requirementString else {
            return "unavailable(\(stringStatus))"
        }

        return requirementString as String
    }
}
