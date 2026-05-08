//
//  ContentView.swift
//  falsoai-lens
//
//  Created by Carlos Garcia on 24/04/26.
//

import AppKit
import CoreAudio
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @StateObject private var pipeline = DemoScanPipeline()
    @StateObject private var hearing = HearingDemoPipeline()
    @StateObject private var computerHearing = LiveAudioTranscriptionPipeline.computer()
    @StateObject private var microphoneHearing = LiveAudioTranscriptionPipeline.microphone()
    @StateObject private var duplicateAnalyzer = TranscriptDuplicateAnalyzer()
    @StateObject private var audioInputDevices = AudioInputDevicePickerViewModel()
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
            ScrollView {
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
                            .frame(minHeight: 240, maxHeight: 420)
                            .background(Color(nsColor: .textBackgroundColor))
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                        }
                        .frame(maxWidth: .infinity, alignment: .topLeading)
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
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .padding()
            }
        }
        .task {
            await refreshPermissions()
            audioInputDevices.refresh()
            microphoneHearing.setInputDeviceID(audioInputDevices.selectedDeviceID)

            let analyzer = duplicateAnalyzer
            computerHearing.setChunkHook { [weak analyzer] event in
                Task { @MainActor in
                    analyzer?.ingest(event)
                }
            }
            microphoneHearing.setChunkHook { [weak analyzer] event in
                Task { @MainActor in
                    analyzer?.ingest(event)
                }
            }
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

    private var isLiveAudioRunning: Bool {
        computerHearing.isRunning || microphoneHearing.isRunning
    }

    private var isLiveAudioProcessing: Bool {
        computerHearing.isProcessingChunk || microphoneHearing.isProcessingChunk
    }

    private var isLiveAudioAvailable: Bool {
        computerHearing.isAvailable || microphoneHearing.isAvailable
    }

    private var hasLiveTranscriptText: Bool {
        computerHearing.hasTranscriptText || microphoneHearing.hasTranscriptText
    }

    private var hasLiveAudioError: Bool {
        computerHearing.errorMessage != nil || microphoneHearing.errorMessage != nil
    }

    private var liveTranscriptDocument: SourceSeparatedAudioTranscript {
        SourceSeparatedAudioTranscript(
            language: microphoneHearing.transcript.latestLanguage
                ?? computerHearing.transcript.latestLanguage,
            mode: hearingMode,
            sources: [
                computerHearing.transcriptSource,
                microphoneHearing.transcriptSource
            ],
            chunks: computerHearing.transcript.chunks
                + microphoneHearing.transcript.chunks,
            annotations: duplicateAnalyzer.annotations
        )
    }

    private func startLiveAudioPipelines() async {
        await computerHearing.start(mode: hearingMode)
        await microphoneHearing.start(mode: hearingMode)
    }

    private func stopLiveAudioPipelines() async {
        await computerHearing.stop()
        await microphoneHearing.stop()
    }

    private func clearLiveAudioTranscripts() {
        #if DEBUG
        _ = liveTranscriptDocument
        #endif

        computerHearing.clearTranscript()
        microphoneHearing.clearTranscript()
        duplicateAnalyzer.reset()
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

            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label("Independent Live Audio", systemImage: "waveform.and.person.filled")
                        .font(.headline)
                    Spacer()
                    if hasLiveTranscriptText {
                        Text("Computer \(computerHearing.transcript.chunksTranscribed) | Mic \(microphoneHearing.transcript.chunksTranscribed) | Dups \(duplicateAnalyzer.annotations.count)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

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

                HStack {
                    Button {
                        Task {
                            if isLiveAudioRunning {
                                await stopLiveAudioPipelines()
                            } else {
                                await startLiveAudioPipelines()
                            }
                        }
                    } label: {
                        Label(
                            isLiveAudioRunning ? "Stop Capture" : "Start Capture",
                            systemImage: isLiveAudioRunning ? "stop.circle" : "record.circle"
                        )
                    }
                    .disabled(!isLiveAudioAvailable && !isLiveAudioRunning)

                    Button {
                        clearLiveAudioTranscripts()
                    } label: {
                        Label("Clear Both", systemImage: "trash")
                    }
                    .disabled(!hasLiveTranscriptText && !hasLiveAudioError)
                }

                HStack(alignment: .top, spacing: 10) {
                    VStack(alignment: .leading, spacing: 4) {
                        Label(
                            computerHearing.statusText,
                            systemImage: computerHearing.isRunning ? "desktopcomputer" : "waveform.slash"
                        )
                        Label(
                            microphoneHearing.statusText,
                            systemImage: microphoneHearing.isRunning ? "mic" : "waveform.slash"
                        )
                    }
                    .font(.callout)
                    .foregroundStyle(.secondary)

                    if isLiveAudioProcessing {
                        ProgressView()
                            .controlSize(.small)
                    }
                }

                VStack(alignment: .leading, spacing: 14) {
                    liveTranscriptPanel(
                        title: "Computer Audio",
                        subtitle: "System audio captured from the selected display",
                        systemImage: "desktopcomputer",
                        state: computerHearing.transcript,
                        accent: .blue
                    ) {
                        copyToPasteboard(computerHearing.transcript.text)
                    }

                    liveTranscriptPanel(
                        title: "Microphone",
                        subtitle: "External input captured from the active microphone",
                        systemImage: "mic",
                        state: microphoneHearing.transcript,
                        accent: .green
                    ) {
                        copyToPasteboard(microphoneHearing.transcript.text)
                    }
                }

                if let computerError = computerHearing.errorMessage {
                    Text("Computer audio: \(computerError)")
                        .font(.callout)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }

                if let microphoneError = microphoneHearing.errorMessage {
                    Text("Microphone: \(microphoneError)")
                        .font(.callout)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }

                if let inputDeviceError = audioInputDevices.errorMessage {
                    Text("Audio inputs: \(inputDeviceError)")
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

    private func liveTranscriptPanel(
        title: String,
        subtitle: String,
        systemImage: String,
        state: SourceTranscriptState,
        accent: Color,
        copyAction: @escaping () -> Void
    ) -> some View {
        #if DEBUG
        if title == "Computer Audio" {
            assert(state.source == .computer, "Computer panel must receive computer transcript state")
        }
        if title == "Microphone" {
            assert(state.source == .microphone, "Microphone panel must receive microphone transcript state")
        }
        #endif

        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Label(title, systemImage: systemImage)
                    .font(.headline)
                    .foregroundStyle(accent)
                Spacer()

                Button {
                    copyAction()
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
                .disabled(state.isEmpty)
            }

            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)

            ScrollView {
                Text(state.isEmpty ? "No transcript yet" : state.text)
                    .font(.body)
                    .foregroundStyle(state.isEmpty ? .secondary : .primary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }
            .frame(minHeight: 150, maxHeight: 260)
            .background(Color(nsColor: .textBackgroundColor))
            .overlay(alignment: .leading) {
                Rectangle()
                    .fill(accent)
                    .frame(width: 3)
            }
            .clipShape(RoundedRectangle(cornerRadius: 6))

            HStack(spacing: 12) {
                Label("\(state.chunksTranscribed) chunks", systemImage: "waveform")
                if let elapsed = state.lastInferenceDurationSeconds {
                    Label(String(format: "%.2f s", elapsed), systemImage: "timer")
                }
                if let language = state.latestLanguage {
                    Label(language, systemImage: "globe")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("Chunk Objects")
                    .font(.subheadline.weight(.semibold))

                if state.chunks.isEmpty {
                    Text("No chunks yet")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 4)
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(state.chunks) { chunk in
                                chunkObjectRow(chunk)

                                if chunk.id != state.chunks.last?.id {
                                    Divider()
                                }
                            }
                        }
                    }
                    .frame(minHeight: 120, maxHeight: 240)
                    .background(Color(nsColor: .textBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .padding(12)
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(accent.opacity(0.35), lineWidth: 1)
        }
    }

    private func chunkObjectRow(_ chunk: SourceTranscriptChunk) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(chunk.chunkID)
                    .font(.system(.caption, design: .monospaced).weight(.semibold))
                Spacer()
                Text(chunk.source.displayName)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 10) {
                Label(formatRange(start: chunk.startTime, end: chunk.endTime), systemImage: "clock")
                Label(formatDuration(chunk.duration), systemImage: "timer")
                Text("seq \(chunk.sequenceNumber)")
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            if let language = chunk.language {
                Text("language: \(language)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text(chunk.text)
                .font(.callout)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func formatRange(start: TimeInterval?, end: TimeInterval?) -> String {
        let startText = formatTimestamp(start) ?? "--:--.--"
        let endText = formatTimestamp(end) ?? "--:--.--"
        return "[\(startText) → \(endText)]"
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        String(format: "%.2f s", seconds)
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
