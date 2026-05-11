import SwiftUI

struct AudioTranscriptCacheBrowserView: View {
    @ObservedObject var viewModel: AudioTranscriptCacheBrowserViewModel
    let copyAction: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Label("Saved Audio Text", systemImage: "externaldrive")
                    .font(.headline)
                Spacer()
                if viewModel.totalRows > 0 {
                    Text("\(viewModel.totalRows) saved")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Button {
                    Task { await viewModel.refresh() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(viewModel.isRefreshing)
            }

            if let errorMessage = viewModel.errorMessage {
                Text(errorMessage)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }

            if viewModel.isRefreshing {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Loading saved audio text...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if !viewModel.hasRows {
                Text("No saved audio text yet")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 8)
            } else {
                LazyVStack(alignment: .leading, spacing: 12) {
                    cacheGroup(
                        title: "Computer Audio Cache",
                        systemImage: "desktopcomputer",
                        rows: viewModel.computerRows,
                        accent: .blue
                    )

                    cacheGroup(
                        title: "Microphone Cache",
                        systemImage: "mic",
                        rows: viewModel.microphoneRows,
                        accent: .green
                    )
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .padding(12)
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.secondary.opacity(0.25), lineWidth: 1)
        }
    }

    private func cacheGroup(
        title: String,
        systemImage: String,
        rows: [AudioTranscriptCacheDisplayRow],
        accent: Color
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Label(title, systemImage: systemImage)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(accent)
                Spacer()
                Text("\(rows.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if rows.isEmpty {
                Text("No saved text for this source")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
            } else {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(rows) { row in
                        cacheRow(row, accent: accent)
                        if row.id != rows.last?.id {
                            Divider()
                        }
                    }
                }
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private func cacheRow(_ row: AudioTranscriptCacheDisplayRow, accent: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(row.chunkID)
                    .font(.system(.caption, design: .monospaced).weight(.semibold))
                Text("seq \(row.sequenceNumber)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    copyAction(row.text)
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
                .controlSize(.small)
            }

            HStack(spacing: 10) {
                Label(row.capturedAt.formatted(date: .abbreviated, time: .standard), systemImage: "calendar")
                Label(formatRange(start: row.startTime, end: row.endTime), systemImage: "clock")
                Label(formatDuration(row.duration), systemImage: "timer")
                if let inferenceDurationSeconds = row.inferenceDurationSeconds {
                    Label(String(format: "%.2f s", inferenceDurationSeconds), systemImage: "cpu")
                }
                if let language = row.language {
                    Label(language, systemImage: "globe")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            Text(row.text)
                .font(.callout)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(10)
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(accent)
                .frame(width: 3)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func formatRange(start: TimeInterval, end: TimeInterval) -> String {
        "\(formatTimestamp(start)) - \(formatTimestamp(end))"
    }

    private func formatTimestamp(_ seconds: TimeInterval) -> String {
        let wholeSeconds = max(0, Int(seconds))
        let minutes = wholeSeconds / 60
        let remainingSeconds = wholeSeconds % 60
        let centiseconds = Int((seconds - Double(wholeSeconds)) * 100)
        return String(format: "%02d:%02d.%02d", minutes, remainingSeconds, max(0, centiseconds))
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        String(format: "%.2f s", seconds)
    }
}
