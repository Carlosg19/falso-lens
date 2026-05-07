import SwiftUI
import Vision
import ScreenCaptureKit
import AVFoundation
import UserNotifications
import SwiftData
import GRDB
import AppKit
import UniformTypeIdentifiers
import ApplicationServices

enum DependencyImports {
    static let configured = true
    static let hearingConfigured = HearingDependencies.captureEngineType == AVAudioEngine.self
}
