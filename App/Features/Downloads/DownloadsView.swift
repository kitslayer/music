import SwiftUI

/// Everything on the phone, grouped the way it was downloaded.
///
/// This doubles as the offline browser: every entry carries its full song metadata,
/// so this screen renders and plays with the server switched off entirely.
struct DownloadsView: View {
    @Environment(AppState.self) private var appState
    @Environment(Reachability.self) private var reachability

    @State private var confirmsRemoveAll = false

    private var downloads: DownloadCenter { appState.downloads }

    var body: some View {
        List {
            if !downloads.progress.isEmpty {
                Section("Downloading") {
                    ForEach(activeDownloads, id: \.id) { item in
                        ActiveDownloadRow(entry: item.entry, fraction: item.fraction)
                    }
                }
            }

            ForEach(groups) { group in
                Section {
                    ForEach(Array(group.songs.enumerated()), id: \.element.id) { index, _ in
                        PlayableSongRow(
                            songs: group.songs,
                            index: index,
                            source: group.name,
                            style: .numbered(index + 1)
                        )
                        .alignmentGuide(.listRowSeparatorLeading) { _ in 36 }
                    }
                } header: {
                    GroupHeader(group: group)
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Downloads")
        .toolbar {
            if !downloads.catalog.entries.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("Shuffle All", systemImage: "shuffle") {
                            appState.player.play(
                                songs: allSongs.shuffled(),
                                startingAt: 0,
                                source: "Downloads"
                            )
                        }
                        Divider()
                        Button("Remove All Downloads", systemImage: "trash", role: .destructive) {
                            confirmsRemoveAll = true
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
        }
        .confirmationDialog(
            "Remove all downloads?",
            isPresented: $confirmsRemoveAll,
            titleVisibility: .visible
        ) {
            Button("Remove \(sizeText)", role: .destructive) {
                downloads.removeAll()
            }
        } message: {
            Text("The music stays on your server. Only the copies on this phone are deleted.")
        }
        .overlay {
            if downloads.catalog.entries.isEmpty, downloads.progress.isEmpty {
                ContentUnavailableView(
                    "No Downloads",
                    systemImage: "arrow.down.circle",
                    description: Text(
                        "Download an album, playlist or song to keep it on this phone."
                    )
                )
            }
        }
        .safeAreaInset(edge: .bottom) {
            if !downloads.catalog.entries.isEmpty {
                footer
            }
        }
    }

    private var footer: some View {
        VStack(spacing: 2) {
            Text("\(downloads.catalog.entries.count) songs · \(sizeText)")
            if !reachability.isOnline {
                Text("Offline — playing from this phone")
                    .foregroundStyle(Color.appTint)
            }
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background(.bar)
    }

    private var sizeText: String {
        downloads.catalog.totalBytes.asFileSize
    }

    // MARK: - Grouping

    struct Group: Identifiable {
        let id: String
        let name: String
        let subtitle: String
        let coverArt: String?
        let songs: [Song]
        /// Most recent download in the group, which is the sort order.
        let addedAt: Date
    }

    private var allSongs: [Song] {
        groups.flatMap(\.songs)
    }

    /// Grouped by the album or playlist the download was requested as, newest first,
    /// because the thing you just downloaded is the thing you are looking for.
    private var groups: [Group] {
        let entries = Array(downloads.catalog.entries.values)
        let keyed = Dictionary(grouping: entries) { entry in
            entry.groupID ?? entry.song.albumId ?? entry.song.id
        }

        return keyed.compactMap { key, group -> Group? in
            let sorted = group.sorted { $0.song.albumOrder < $1.song.albumOrder }
            guard let first = sorted.first else { return nil }
            let bytes = group.reduce(Int64(0)) { $0 + $1.byteCount }

            return Group(
                id: key,
                name: first.groupName ?? first.song.album ?? first.song.title,
                subtitle: "\(group.count) songs · \(bytes.asFileSize)",
                coverArt: first.song.coverArt,
                songs: sorted.map(\.song),
                addedAt: group.map(\.addedAt).max() ?? .distantPast
            )
        }
        .sorted { $0.addedAt > $1.addedAt }
    }

    private var activeDownloads: [(id: String, entry: DownloadCatalog.Entry, fraction: Double)] {
        downloads.progress.compactMap { songID, fraction in
            guard let entry = downloads.catalog.pending[songID] else { return nil }
            return (id: songID, entry: entry, fraction: fraction)
        }
        .sorted { $0.entry.song.albumOrder < $1.entry.song.albumOrder }
    }
}

private struct GroupHeader: View {
    @Environment(AppState.self) private var appState

    let group: DownloadsView.Group

    var body: some View {
        HStack(spacing: Metrics.itemSpacing) {
            ArtworkImage(id: group.coverArt, size: .thumb, cornerRadius: Metrics.radiusThumb)
                .frame(width: Metrics.thumbRow, height: Metrics.thumbRow)

            VStack(alignment: .leading, spacing: 2) {
                Text(group.name)
                    .font(.headline)
                    .textCase(nil)
                    .lineLimit(1)
                Text(group.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textCase(nil)
            }

            Spacer(minLength: 8)

            Button {
                appState.downloads.remove(group.songs.map(\.id))
            } label: {
                Image(systemName: "trash")
                    .foregroundStyle(.secondary)
                    .frame(minWidth: Metrics.minimumTouchTarget, minHeight: Metrics.minimumTouchTarget)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove \(group.name)")
        }
        .padding(.vertical, 4)
    }
}

private struct ActiveDownloadRow: View {
    @Environment(AppState.self) private var appState

    let entry: DownloadCatalog.Entry
    let fraction: Double

    var body: some View {
        HStack(spacing: Metrics.itemSpacing) {
            VStack(alignment: .leading, spacing: 6) {
                Text(entry.song.title)
                    .lineLimit(1)
                ProgressView(value: fraction)
                    .tint(.appTint)
            }

            Button {
                appState.downloads.remove([entry.song.id])
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Cancel download")
        }
    }
}
