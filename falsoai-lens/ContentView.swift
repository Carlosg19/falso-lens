//
//  ContentView.swift
//  falsoai-lens
//
//  Created by Carlos Garcia on 24/04/26.
//

import AppKit
import CoreAudio
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @StateObject private var screenText = ScreenTextPipeline()
    @StateObject private var realtimeScreenText = RealtimeScreenTextPipeline()
    @StateObject private var hearing = FileTranscriptionPipeline()
    @StateObject private var computerHearing = LiveAudioTranscriptionPipeline.computer()
    @StateObject private var microphoneHearing = LiveAudioTranscriptionPipeline.microphone()
    @StateObject private var duplicateAnalyzer = TranscriptDuplicateAnalyzer()
    @StateObject private var audioInputDevices = AudioInputDevicePickerViewModel()
    @StateObject private var audioTranscriptCacheBrowser = AudioTranscriptCacheBrowserViewModel()
    @State private var hearingMode: TranscriptionMode = .translateToEnglish
    @State private var screenTextExportMode: ScreenTextExportMode = .markdown
    @State private var permissionSnapshot: PermissionSnapshot?
    @State private var permissionDebugSummary = "Permissions not checked yet"
    @State private var lastPermissionAction = "No permission action yet"
    @State private var runtimePermissionIdentity: RuntimePermissionIdentity?
    private let permissionManager = PermissionManager()
    private let notificationService = NotificationService()
    private let screenTextLLMExporter = ScreenTextLLMExporter()

    private enum ScreenTextExportMode: String, CaseIterable, Identifiable {
        case markdown
        case chunks

        var id: Self { self }

        var title: String {
            switch self {
            case .markdown:
                return "Markdown"
            case .chunks:
                return "Chunks"
            }
        }
    }

    var body: some View {
        NavigationSplitView {
            List {
                Section("Permissions") {
                    permissionRow("Screen", permissionSnapshot?.screenRecording)
                    permissionRow("Accessibility", permissionSnapshot?.accessibility)
                    permissionRow("Notifications", permissionSnapshot?.notifications)
                    permissionRow("Microphone", permissionSnapshot?.microphone)
                }

                Section("Realtime Screen Text Cache") {
                    if realtimeScreenText.recentSnapshots.isEmpty {
                        Text("No realtime snapshots yet")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(realtimeScreenText.recentSnapshots) { snapshot in
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Sample \(snapshot.sequenceNumber)")
                                    .font(.headline)
                                Text(snapshot.recognizedText)
                                    .lineLimit(2)
                                    .foregroundStyle(.secondary)
                                Text("\(snapshot.displayCount) displays | \(snapshot.recognizedText.count) chars | \(snapshot.capturedAt.formatted(date: .omitted, time: .standard))")
                                    .font(.caption)
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
                    realtimeScreenText.refreshRecentSnapshots()
                }
            }
        } detail: {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Screen Text Capture")
                            .font(.title)
                        Text("Capture the main display and save recognized text locally.")
                            .foregroundStyle(.secondary)
                    }

                    HStack {
                        Button {
                            Task { await screenText.captureScreenText() }
                        } label: {
                            Label(
                                screenText.isCapturingScreen ? "Capturing" : "Capture Screen Text",
                                systemImage: "text.viewfinder"
                            )
                        }
                        .disabled(screenText.isCapturingScreen)

                        Button("Request Screen Recording") {
                            let granted = permissionManager.requestScreenRecordingPermission()
                            lastPermissionAction = "Screen recording request returned \(granted). If you just granted access, quit and reopen the app."
                            Task { await refreshPermissions() }
                        }
                    }

                    Text(screenText.captureStatus)
                        .font(.callout)
                        .foregroundStyle(.secondary)

                    realtimeScreenTextPanel
                    realtimeEncounteredTextSection
                    realtimeCachedTextSection

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

                    if let document = screenText.latestDocument, !screenText.lastOCRText.isEmpty {
                        screenTextExportPanel(for: document)
                    }

                    if let errorMessage = screenText.errorMessage {
                        Text(errorMessage)
                            .foregroundStyle(.red)
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
            await audioTranscriptCacheBrowser.refresh()

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
        .onDisappear {
            realtimeScreenText.stop()
        }
    }

    private func screenTextExportPanel(for document: MultiDisplayScreenTextDocument) -> some View {
        let exportedDocument = screenTextLLMExporter.export(document)
        let markdown = screenTextLLMExporter.anchoredMarkdown(from: exportedDocument)
        let chunks = screenTextLLMExporter.chunks(from: exportedDocument)

        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("LLM Screen Text Export")
                    .font(.headline)
                Spacer()
                Text(screenTextExportMode == .markdown ? "\(markdown.count) chars" : "\(chunks.count) chunks")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 12) {
                Label("\(document.displays.count) displays", systemImage: "display.2")
                Label("\(document.observationCount) observations", systemImage: "text.magnifyingglass")
                Label("\(document.lineCount) lines", systemImage: "text.line.first.and.arrowtriangle.forward")
                Label("\(document.blockCount) blocks", systemImage: "text.alignleft")
                Label("\(document.regionCount) regions", systemImage: "rectangle.3.group")
                Label(
                    screenText.lastCaptureUsedCache ? "Memory cache" : "Fresh OCR",
                    systemImage: screenText.lastCaptureUsedCache ? "memorychip" : "camera.viewfinder"
                )
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            Text(
                document.displays
                    .map { display in
                        "Display \(display.index + 1): \(Int(display.document.frameSize.width)) x \(Int(display.document.frameSize.height))"
                    }
                    .joined(separator: " | ")
                + " | captured \(document.capturedAt.formatted(date: .omitted, time: .standard))"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .textSelection(.enabled)

            HStack {
                Picker("Export View", selection: $screenTextExportMode) {
                    ForEach(ScreenTextExportMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 260)

                Spacer()

                Button {
                    copyToPasteboard(screenTextExportText(markdown: markdown, chunks: chunks))
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
            }

            screenTextExportContent(markdown: markdown, chunks: chunks)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .padding()
        .background(.thinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private func screenTextExportContent(markdown: String, chunks: [ScreenTextLLMChunk]) -> some View {
        switch screenTextExportMode {
        case .markdown:
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Anchored Markdown")
                        .font(.subheadline.weight(.semibold))
                    Text(markdown)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .foregroundStyle(.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(8)
            }
            .frame(minHeight: 240, maxHeight: 420)
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 6))
        case .chunks:
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if chunks.isEmpty {
                        Text("No export chunks available.")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        ForEach(chunks, id: \.alias) { chunk in
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Text(chunk.alias)
                                        .font(.system(.caption, design: .monospaced).weight(.semibold))
                                    Spacer()
                                    Text("\(chunk.characterCount) chars")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }

                                Text("displayAlias: \(chunk.displayAlias) | regionAliases: \(chunk.regionAliases.joined(separator: ", "))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)

                                Text(chunk.text)
                                    .font(.system(.body, design: .monospaced))
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .padding(8)
                            .background(Color(nsColor: .controlBackgroundColor))
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                        }
                    }
                }
                .padding(8)
            }
            .frame(minHeight: 240, maxHeight: 420)
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }

    private func screenTextExportText(markdown: String, chunks: [ScreenTextLLMChunk]) -> String {
        switch screenTextExportMode {
        case .markdown:
            return markdown
        case .chunks:
            return chunks
                .map { chunk in
                    [
                        "[\(chunk.alias)]",
                        "displayAlias: \(chunk.displayAlias)",
                        "regionAliases: \(chunk.regionAliases.joined(separator: ", "))",
                        chunk.text
                    ].joined(separator: "\n")
                }
                .joined(separator: "\n\n")
        }
    }

    private func encounteredTextExport(_ encounters: [ScreenTextEncounter]) -> String {
        encounters
            .map { encounter in
                let firstSeen = encounter.firstSeenAt.formatted(date: .omitted, time: .standard)
                let lastSeen = encounter.lastSeenAt.formatted(date: .omitted, time: .standard)
                let displayLabel = "Display \(encounter.latestSource.displayIndex + 1)"

                return [
                    "[\(firstSeen)-\(lastSeen)] \(displayLabel) seen \(encounter.seenCount)x",
                    encounter.text
                ].joined(separator: "\n")
            }
            .joined(separator: "\n\n")
    }

    private func encounteredTextOnlyExport(_ encounters: [ScreenTextEncounter]) -> String {
        encounters
            .map(\.text)
            .joined(separator: "\n\n")
    }

    private var realtimeScreenTextPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Realtime Screen Text")
                    .font(.headline)
                Spacer()
                Text(realtimeScreenText.isRunning ? "Recording" : "Stopped")
                    .font(.caption)
                    .foregroundStyle(realtimeScreenText.isRunning ? .green : .secondary)
            }

            HStack {
                Button {
                    if realtimeScreenText.isRunning {
                        realtimeScreenText.stop()
                    } else {
                        realtimeScreenText.start()
                    }
                } label: {
                    Label(
                        realtimeScreenText.isRunning ? "Stop" : "Start",
                        systemImage: realtimeScreenText.isRunning ? "stop.circle" : "record.circle"
                    )
                }

                Button {
                    realtimeScreenText.clearCache()
                } label: {
                    Label("Clear Cache", systemImage: "trash")
                }
                .disabled(realtimeScreenText.isRunning || realtimeScreenText.recentSnapshots.isEmpty)

                Spacer()

                if realtimeScreenText.isSampling {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            HStack(spacing: 12) {
                Label("\(realtimeScreenText.samplesCaptured) samples", systemImage: "camera.metering.center.weighted")
                Label("\(realtimeScreenText.snapshotsCached) cached", systemImage: "externaldrive")
                Label("\(realtimeScreenText.duplicateSamplesSkipped) duplicates skipped", systemImage: "equal.circle")
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            Text(realtimeScreenText.statusText)
                .font(.callout)
                .foregroundStyle(.secondary)

            if let latestSnapshot = realtimeScreenText.latestSnapshot {
                Text("\(latestSnapshot.displayCount) displays | \(latestSnapshot.observationCount) observations | \(latestSnapshot.ocrDisplayCount) OCR displays | \(latestSnapshot.reusedDisplayCount) cached displays | \(latestSnapshot.elapsedSeconds.formatted(.number.precision(.fractionLength(2))))s")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            if let errorMessage = realtimeScreenText.errorMessage {
                Text(errorMessage)
                    .font(.callout)
                    .foregroundStyle(.red)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .padding()
        .background(.thinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var realtimeEncounteredTextSection: some View {
        let encounters = realtimeScreenText.recentEncounters
        let retainedText = encounteredTextOnlyExport(encounters)
        let detailText = encounteredTextExport(encounters)
        let totalSightings = encounters.reduce(0) { $0 + $1.seenCount }

        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Last 5 Minutes Screen Text")
                    .font(.headline)
                Spacer()
                Text("\(encounters.count) unique lines | \(totalSightings) sightings")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button {
                    copyToPasteboard(retainedText)
                } label: {
                    Label("Copy Text", systemImage: "doc.on.doc")
                }
                .disabled(retainedText.isEmpty)

                Button {
                    copyToPasteboard(detailText)
                } label: {
                    Label("Copy Details", systemImage: "list.bullet.clipboard")
                }
                .disabled(detailText.isEmpty)
            }

            ScrollView {
                Text(retainedText.isEmpty ? "No screen text encountered yet." : retainedText)
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(retainedText.isEmpty ? .secondary : .primary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }
            .frame(minHeight: 220, maxHeight: 360)
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .padding()
        .background(.thinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var realtimeCachedTextSection: some View {
        let cachedSnapshot = realtimeScreenText.recentSnapshots.first
        let cachedText = cachedSnapshot?.recognizedText.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Realtime Cached Text")
                    .font(.headline)
                Spacer()
                if let cachedSnapshot {
                    Text("Sample \(cachedSnapshot.sequenceNumber)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Button {
                    copyToPasteboard(cachedText)
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
                .disabled(cachedText.isEmpty)
            }

            if let cachedSnapshot {
                HStack(spacing: 12) {
                    Label("\(cachedSnapshot.displayCount) displays", systemImage: "display.2")
                    Label("\(cachedText.count) chars", systemImage: "textformat.size")
                    Label(cachedSnapshot.capturedAt.formatted(date: .omitted, time: .standard), systemImage: "clock")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            ScrollView {
                Text(cachedText.isEmpty ? "No cached text yet." : cachedText)
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(cachedText.isEmpty ? .secondary : .primary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }
            .frame(minHeight: 180, maxHeight: 320)
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .padding()
        .background(.thinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 8))
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

    private func annotation(for chunkID: String) -> DuplicateAnnotation? {
        duplicateAnalyzer.annotations.first { $0.chunkID == chunkID }
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
        await audioTranscriptCacheBrowser.refresh()
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

                    AudioTranscriptCacheBrowserView(
                        viewModel: audioTranscriptCacheBrowser,
                        copyAction: copyToPasteboard
                    )
                }

                if !duplicateAnalyzer.annotations.isEmpty {
                    duplicateSummarySection
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
                                chunkObjectRow(chunk, annotation: annotation(for: chunk.chunkID))

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

    private func chunkObjectRow(
        _ chunk: SourceTranscriptChunk,
        annotation: DuplicateAnnotation? = nil
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(chunk.chunkID)
                    .font(.system(.caption, design: .monospaced).weight(.semibold))
                if annotation != nil {
                    Label("Duplicate", systemImage: "doc.on.doc.fill")
                        .labelStyle(.titleAndIcon)
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.orange.opacity(0.18), in: Capsule())
                        .foregroundStyle(.orange)
                }
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

            if let annotation {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Duplicate of \(annotation.duplicateOfChunkID) · \(formatConfidence(annotation.confidence))")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.orange)
                    if !annotation.signals.isEmpty {
                        Text("Signals: \(annotation.signals.joined(separator: ", "))")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(annotation != nil ? Color.orange.opacity(0.06) : Color.clear)
    }

    private func formatConfidence(_ value: Double) -> String {
        "\(Int((value * 100).rounded()))%"
    }

    private func formatRange(start: TimeInterval?, end: TimeInterval?) -> String {
        let startText = formatTimestamp(start) ?? "--:--.--"
        let endText = formatTimestamp(end) ?? "--:--.--"
        return "[\(startText) → \(endText)]"
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        String(format: "%.2f s", seconds)
    }

    private var duplicateSummarySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Label("Cross-source Duplicates", systemImage: "doc.on.doc")
                    .font(.headline)
                    .foregroundStyle(.orange)
                Spacer()
                Text("\(duplicateAnalyzer.annotations.count) flagged")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text("Chunks the analyzer believes are the same utterance heard on both inputs. Confidence weights text overlap, PCM correlation, timing, language, and duration.")
                .font(.caption)
                .foregroundStyle(.secondary)

            ForEach(duplicateAnalyzer.annotations) { annotation in
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("\(annotation.chunkID)  ↔  \(annotation.duplicateOfChunkID)")
                            .font(.system(.caption, design: .monospaced).weight(.semibold))
                        Spacer()
                        Text(formatConfidence(annotation.confidence))
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.orange)
                    }
                    if !annotation.signals.isEmpty {
                        Text(annotation.signals.joined(separator: " · "))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)

                if annotation.id != duplicateAnalyzer.annotations.last?.id {
                    Divider()
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.orange.opacity(0.35), lineWidth: 1)
        }
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
}
