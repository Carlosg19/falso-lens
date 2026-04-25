//
//  ContentView.swift
//  falsoai-lens
//
//  Created by Carlos Garcia on 24/04/26.
//

import SwiftData
import SwiftUI

struct ContentView: View {
    @StateObject private var pipeline = DemoScanPipeline()
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
                        Text("Last OCR Capture")
                            .font(.headline)
                        Text(pipeline.lastOCRText)
                            .lineLimit(6)
                            .textSelection(.enabled)
                            .foregroundStyle(.secondary)
                    }
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

                Spacer()
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
}

#Preview {
    ContentView()
        .modelContainer(for: Item.self, inMemory: true)
}
