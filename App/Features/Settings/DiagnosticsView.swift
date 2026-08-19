import SwiftUI

/// What is pending, and what has gone wrong.
///
/// Both halves exist for the same reason: nothing else in the app can tell you that a
/// scrobble is stuck or that a download quietly failed. With no debugger on this device,
/// this screen is the difference between "it didn't work" and a fixable report.
struct DiagnosticsView: View {
    @Environment(AppState.self) private var appState
    @Environment(DownloadCenter.self) private var downloads
    @Environment(QueueSync.self) private var queueSync

    @State private var pending: [ServerOutbox.Kind: Int] = [:]
    @State private var lines: [Diagnostics.Line] = []
    @State private var isFlushing = false

    var body: some View {
        List {
            Section {
                if pending.isEmpty {
                    LabeledContent("Waiting to sync", value: "Nothing")
                } else {
                    ForEach(Array(pending.keys.sorted(by: { $0.rawValue < $1.rawValue })), id: \.self) { kind in
                        LabeledContent(label(for: kind), value: "\(pending[kind] ?? 0)")
                    }
                }

                Button {
                    flush()
                } label: {
                    HStack {
                        Text("Sync Now")
                        Spacer()
                        if isFlushing { ProgressView().controlSize(.small) }
                    }
                }
                .disabled(isFlushing || pending.isEmpty)
            } header: {
                Text("Pending")
            } footer: {
                Text("""
                Plays, stars and ratings made while offline wait here and are sent when \
                the server is reachable. They carry the time they actually happened, so \
                a late one is still recorded correctly.
                """)
            }

            Section("Sync") {
                LabeledContent(
                    "Queue Uploaded",
                    value: queueSync.lastPushedAt.map {
                        $0.formatted(date: .omitted, time: .shortened)
                    } ?? "Not yet"
                )
                LabeledContent("Downloads", value: "\(downloads.catalog.entries.count)")
                if !downloads.progress.isEmpty {
                    LabeledContent("Downloading", value: "\(downloads.progress.count)")
                }
                if let pendingCount = downloadsPending, pendingCount > 0 {
                    LabeledContent("Stalled Downloads", value: "\(pendingCount)")
                }
            }

            Section {
                if lines.isEmpty {
                    Text("Nothing has failed.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(lines) { line in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(line.message)
                                .font(.caption)
                                .textSelection(.enabled)
                            Text("\(line.area) · \(line.at.formatted(date: .omitted, time: .standard))")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            } header: {
                HStack {
                    Text("Recent Failures")
                    Spacer()
                    if !lines.isEmpty {
                        ShareLink(item: exportText) {
                            Text("Share").font(.caption).textCase(nil)
                        }
                    }
                }
            } footer: {
                Text("Request URLs are stripped of their query, which is where the auth token lives.")
            }

            if !lines.isEmpty {
                Section {
                    Button("Clear Log", role: .destructive) {
                        Task {
                            await Diagnostics.shared.clear()
                            lines = []
                        }
                    }
                }
            }
        }
        .navigationTitle("Diagnostics")
        .refreshable { await reload() }
        .task { await reload() }
    }

    /// Pending entries whose transfer is not running: written before the transfer
    /// started, so any left with no progress is one that never got going.
    private var downloadsPending: Int? {
        let stalled = downloads.catalog.pending.keys.filter { downloads.progress[$0] == nil }
        return stalled.isEmpty ? nil : stalled.count
    }

    @State private var exportText = ""

    private func label(for kind: ServerOutbox.Kind) -> String {
        switch kind {
        case .scrobble: return "Plays"
        case .star: return "Favourites added"
        case .unstar: return "Favourites removed"
        case .rating: return "Ratings"
        case .bookmark: return "Resume positions"
        }
    }

    private func reload() async {
        pending = await appState.outbox.summary()
        lines = await Diagnostics.shared.recent()
        exportText = await Diagnostics.shared.export()
    }

    private func flush() {
        isFlushing = true
        Task {
            await appState.flushOutbox()
            await reload()
            isFlushing = false
        }
    }
}
