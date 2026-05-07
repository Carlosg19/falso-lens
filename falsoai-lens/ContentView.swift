//
//  ContentView.swift
//  falsoai-lens
//
//  Created by Carlos Garcia on 24/04/26.
//

import AppKit
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @StateObject private var pipeline = DemoScanPipeline()
    @StateObject private var hearing = HearingDemoPipeline()
    @StateObject private var liveHearing = LiveMixedAudioTranscriptionPipeline()
    @State private var hearingMode: TranscriptionMode = .transcribeOriginalLanguage
    @State private var permissionSnapshot: PermissionSnapshot?
    @State private var permissionDebugSummary = "Permissions not checked yet"
    @State private var lastPermissionAction = "No permission action yet"
    @State private var runtimePermissionIdentity: RuntimePermissionIdentity?
    @State private var demoText = "Limited time offer: act now before they hide the truth from you."
    private let permissionManager = PermissionManager()
    private let notificationService = NotificationService()

    var body: some View {
        NavigationSplitView {
            List {
                Section("Permissions") {
                    permissionRow("Screen", permissionSnapshot?.screenRecording)
                    permissionRow("Accessibility", permissionSnapshot?.accessibility)
                    permissionRow("Notifications", permissionSnapshot?.notifications)
                    permissionRow("Microphone", permissionSnapshot?.microphone)
                }

                Section("Recent Scans") {
                    if pipeline.recentScans.isEmpty {
                        Text("No scans yet")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(pipeline.recentScans) { scan in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(scan.analyzerSummary ?? "Scan")
                                    .font(.headline)
                                Text(scan.recognizedText)
                                    .lineLimit(2)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }
            }
            .navigationTitle("Falsoai Lens")
            .toolbar {
                Button("Refresh") {
                    Task { await refreshPermissions() }
                    pipeline.refreshRecentScans()
                }
            }
        } detail: {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Realtime Manipulation Demo")
                        .font(.title)
                    Text("Paste text or capture the main display to exercise screen recording, OCR, analysis, storage, and notifications.")
                        .foregroundStyle(.secondary)
                }

                TextEditor(text: $demoText)
                    .font(.body)
                    .frame(minHeight: 140)
                    .padding(6)
                    .overlay {
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.secondary.opacity(0.25), lineWidth: 1)
                    }

                HStack {
                    Button {
                        Task { await pipeline.scan(text: demoText) }
                    } label: {
                        Label(pipeline.isScanning ? "Scanning" : "Run Demo Scan", systemImage: "viewfinder")
                    }
                    .disabled(pipeline.isScanning)

                    Button {
                        Task { await pipeline.captureScreenOCRAndScan() }
                    } label: {
                        Label(
                            pipeline.isCapturingScreen ? "Capturing" : "Capture Screen + OCR",
                            systemImage: "text.viewfinder"
                        )
                    }
                    .disabled(pipeline.isCapturingScreen || pipeline.isScanning)

                    Button("Request Screen Recording") {
                        let granted = permissionManager.requestScreenRecordingPermission()
                        lastPermissionAction = "Screen recording request returned \(granted). If you just granted access, quit and reopen the app."
                        Task { await refreshPermissions() }
                    }
                }

                Text(pipeline.captureStatus)
                    .font(.callout)
                    .foregroundStyle(.secondary)

                Text(permissionDebugSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)

                Text(lastPermissionAction)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)

                if let runtimePermissionIdentity {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Permission Identity")
                            .font(.headline)
                        Text(runtimePermissionIdentity.expandedSummary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                        Text("Reset: \(runtimePermissionIdentity.tccResetCommand)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                        Text("Reset all ScreenCapture: \(runtimePermissionIdentity.tccResetAllCommand)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                        Text(runtimePermissionIdentity.screenRecordingDiagnosis)
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .textSelection(.enabled)
                    }
                    .padding()
                    .background(.thinMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }

                HStack {
                    Button("Request Notifications") {
                        Task {
                            let granted = (try? await notificationService.requestAuthorization()) ?? false
                            lastPermissionAction = "Notifications request returned \(granted)."
                            await refreshPermissions()
                        }
                    }

                    Button("Request Accessibility") {
                        let status = permissionManager.accessibilityStatus(prompt: true)
                        lastPermissionAction = "Accessibility prompt returned \(label(for: status))."
                        Task { await refreshPermissions() }
                    }

                    Button("Request Microphone") {
                        Task {
                            let granted = await permissionManager.requestMicrophoneAccess()
                            lastPermissionAction = "Microphone request returned \(granted)."
                            await refreshPermissions()
                        }
                    }
                }

                if !pipeline.lastOCRText.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Last OCR Capture")
                                .font(.headline)
                            Spacer()
                            Text("\(pipeline.lastOCRText.count) chars")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        ScrollView {
                            Text(pipeline.lastOCRText)
                                .font(.system(.body, design: .monospaced))
                                .textSelection(.enabled)
                                .foregroundStyle(.primary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(8)
                        }
                        .frame(minHeight: 320, maxHeight: .infinity)
                        .background(Color(nsColor: .textBackgroundColor))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding()
                    .background(.thinMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }

                if let errorMessage = pipeline.errorMessage {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                }

                if let result = pipeline.latestResult {
                    resultView(result)
                }

                hearingDemoSection

                if pipeline.lastOCRText.isEmpty {
                    Spacer()
                }
            }
            .padding()
        }
        .task {
            await refreshPermissions()
        }
    }

    private func refreshPermissions() async {
        let snapshot = await permissionManager.currentSnapshot()
        let identity = permissionManager.runtimeIdentity()
        permissionSnapshot = snapshot
        runtimePermissionIdentity = identity
        permissionDebugSummary = [
            "Bundle: \(identity.bundleIdentifier)",
            "Screen: \(label(for: snapshot.screenRecording))",
            "Accessibility: \(label(for: snapshot.accessibility))",
            "Notifications: \(label(for: snapshot.notifications))",
            "Microphone: \(label(for: snapshot.microphone))"
        ].joined(separator: " | ")
    }

    private func permissionRow(_ title: String, _ status: PermissionStatus?) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(label(for: status))
                .foregroundStyle(status == .authorized ? .green : .secondary)
        }
    }

    private func label(for status: PermissionStatus?) -> String {
        switch status {
        case .authorized:
            return "Allowed"
        case .denied:
            return "Denied"
        case .notDetermined:
            return "Needed"
        case .restricted:
            return "Restricted"
        case .unknown, nil:
            return "Unknown"
        }
    }

    private func resultView(_ result: DemoScanResult) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(result.analyzerResult.summary)
                .font(.headline)
            ProgressView(value: result.analyzerResult.manipulationScore)
            Text("Evidence: \(result.analyzerResult.evidence.joined(separator: ", "))")
                .foregroundStyle(.secondary)
        }
        .padding()
        .background(.thinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var hearingDemoSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Live Audio (Hearing) Demo")
                .font(.title2)

            HStack {
                Button {
                    pickHearingFile()
                } label: {
                    Label("Pick WAV File", systemImage: "doc.badge.plus")
                }

                Picker("Mode", selection: $hearingMode) {
                    ForEach(TranscriptionMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 280)
            }

            HStack {
                Button {
                    Task { await hearing.transcribe(mode: hearingMode) }
                } label: {
                    Label(
                        hearing.isTranscribing ? "Transcribing…" : "Transcribe",
                        systemImage: "waveform.badge.mic"
                    )
                }
                .disabled(
                    hearing.isTranscribing
                        || hearing.lastSelectedFileURL == nil
                        || !hearing.isEngineAvailable
                )

                if let url = hearing.lastSelectedFileURL {
                    Text("Selected: \(url.lastPathComponent)")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            if let elapsed = hearing.lastInferenceDurationSeconds {
                Text(String(format: "Inference: %.2f s", elapsed))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let language = hearing.latestResult?.language {
                Text("Language: \(language)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let result = hearing.latestResult, !result.text.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Transcript")
                        .font(.headline)
                    ScrollView {
                        Text(result.text)
                            .font(.body)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                    }
                    .frame(minHeight: 100, maxHeight: 200)
                    .background(Color(nsColor: .textBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                }

                if !result.segments.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Segments")
                            .font(.headline)
                        ForEach(result.segments) { segment in
                            HStack(alignment: .top, spacing: 8) {
                                Text(formatRange(start: segment.startTime, end: segment.endTime))
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                Text(segment.text.trimmingCharacters(in: .whitespaces))
                                    .font(.callout)
                            }
                        }
                    }
                }
            }

            if let hearingError = hearing.errorMessage {
                Text(hearingError)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }

            Divider()

            VStack(alignment: .leading, spacing: 10) {
                Text("Computer + Mic Live")
                    .font(.headline)

                HStack {
                    Button {
                        Task {
                            if liveHearing.isRunning {
                                await liveHearing.stop()
                            } else {
                                await liveHearing.start(mode: hearingMode)
                            }
                        }
                    } label: {
                        Label(
                            liveHearing.isRunning ? "Stop" : "Start Computer + Mic",
                            systemImage: liveHearing.isRunning ? "stop.circle" : "record.circle"
                        )
                    }
                    .disabled(!liveHearing.isEngineAvailable && !liveHearing.isRunning)

                    Button {
                        liveHearing.clearTranscript()
                    } label: {
                        Label("Clear", systemImage: "trash")
                    }
                    .disabled(liveHearing.transcriptText.isEmpty && liveHearing.errorMessage == nil)

                    Button {
                        copyToPasteboard(liveHearing.transcriptText)
                    } label: {
                        Label("Copy", systemImage: "doc.on.doc")
                    }
                    .disabled(liveHearing.transcriptText.isEmpty)
                }

                HStack(spacing: 12) {
                    Label(liveHearing.statusText, systemImage: liveHearing.isRunning ? "waveform" : "waveform.slash")
                        .font(.callout)
                        .foregroundStyle(.secondary)

                    if liveHearing.isProcessingChunk {
                        ProgressView()
                            .controlSize(.small)
                    }
                }

                HStack(spacing: 12) {
                    if liveHearing.chunksTranscribed > 0 {
                        Text("Chunks: \(liveHearing.chunksTranscribed)")
                    }

                    if let elapsed = liveHearing.lastInferenceDurationSeconds {
                        Text(String(format: "Last inference: %.2f s", elapsed))
                    }

                    if let language = liveHearing.latestLanguage {
                        Text("Language: \(language)")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                if !liveHearing.transcriptText.isEmpty {
                    ScrollView {
                        Text(liveHearing.transcriptText)
                            .font(.body)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                    }
                    .frame(minHeight: 120, maxHeight: 220)
                    .background(Color(nsColor: .textBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                }

                if let liveError = liveHearing.errorMessage {
                    Text(liveError)
                        .font(.callout)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
            }
        }
        .padding()
        .background(.thinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func pickHearingFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.wav, .audio]
        panel.title = "Pick a 16 kHz mono WAV file"
        if panel.runModal() == .OK, let url = panel.url {
            hearing.setSelectedFile(url)
        }
    }

    private func copyToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func formatRange(start: TimeInterval?, end: TimeInterval?) -> String {
        let startText = formatTimestamp(start) ?? "--:--.--"
        let endText = formatTimestamp(end) ?? "--:--.--"
        return "[\(startText) → \(endText)]"
    }

    private func formatTimestamp(_ seconds: TimeInterval?) -> String? {
        guard let seconds else { return nil }
        let minutes = Int(seconds) / 60
        let remaining = seconds - TimeInterval(minutes * 60)
        return String(format: "%02d:%05.2f", minutes, remaining)
    }
}

#Preview {
    ContentView()
        .modelContainer(for: Item.self, inMemory: true)
}
