import SwiftUI

struct PlaylistListView: View {
    @Environment(AppState.self) private var appState
    @Environment(PlaylistStore.self) private var store

    @State private var isCreating = false
    @State private var editing: Playlist?
    @State private var deleting: Playlist?

    private var playlists: [Playlist] { store.playlists }
    private var isLoading: Bool { store.isLoading }

    var body: some View {
        List {
            Section {
                ForEach(playlists) { playlist in
                    NavigationLink(value: Destination.playlist(PlaylistRef(playlist))) {
                        HStack(spacing: Metrics.itemSpacing) {
                            ArtworkImage(
                                id: playlist.coverArt,
                                size: .thumb,
                                cornerRadius: Metrics.radiusThumb
                            )
                            .frame(width: Metrics.thumbPlaylist, height: Metrics.thumbPlaylist)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(playlist.name)
                                    .lineLimit(1)
                                Text(subtitle(for: playlist))
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .frame(minHeight: 64)
                    }
                    .contextMenu {
                        Button("Play", systemImage: "play.fill") { play(playlist) }
                        Button("Shuffle", systemImage: "shuffle") {
                            play(playlist, shuffled: true)
                        }
                        Divider()
                        Button("Rename…", systemImage: "pencil") { editing = playlist }
                        Button("Delete", systemImage: "trash", role: .destructive) {
                            deleting = playlist
                        }
                    }
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            deleting = playlist
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }
            } footer: {
                if !playlists.isEmpty {
                    // Stated once, quietly: the server has no folder parameter for
                    // playlists, so the library switch cannot apply here.
                    Text("Playlists are shown from every library.")
                }
            }
        }
        .listStyle(.plain)
        .navigationTitle("Playlists")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    isCreating = true
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("New playlist")
            }
        }
        .sheet(isPresented: $isCreating) {
            NewPlaylistSheet(songs: [])
        }
        .sheet(item: $editing) { playlist in
            EditPlaylistSheet(playlist: playlist)
        }
        .confirmationDialog(
            deleting.map { "Delete “\($0.name)”?" } ?? "",
            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete Playlist", role: .destructive) {
                if let playlist = deleting {
                    Task { await store.delete(playlist) }
                }
                deleting = nil
            }
        } message: {
            Text("The songs stay in your library.")
        }
        .overlay {
            if isLoading, playlists.isEmpty { ProgressView() }
        }
        .overlay {
            if !isLoading, playlists.isEmpty {
                ContentUnavailableView(
                    "No Playlists",
                    systemImage: "music.note.list",
                    description: Text("Tap + to make one, or add songs from any list.")
                )
            }
        }
        .refreshable { await store.load() }
        .task { await store.loadIfNeeded() }
    }

    private func play(_ playlist: Playlist, shuffled: Bool = false) {
        Task {
            guard let detail = try? await appState.client.playlistDetail(id: playlist.id),
                  !detail.songs.isEmpty
            else { return }
            appState.player.play(
                songs: detail.songs, startingAt: 0, source: playlist.name, shuffled: shuffled
            )
        }
    }

    private func subtitle(for playlist: Playlist) -> String {
        var parts: [String] = []
        if let count = playlist.songCount { parts.append("\(count) songs") }
        if let duration = playlist.duration { parts.append(duration.asLongDuration) }
        return parts.joined(separator: " · ")
    }

}

struct PlaylistDetailView: View {
    @Environment(AppState.self) private var appState
    @Environment(PlaylistStore.self) private var store
    @Environment(LibraryScopeStore.self) private var scope

    let playlist: PlaylistRef

    @State private var detail: PlaylistDetail?
    @State private var selection = SongSelection()

    var body: some View {
        List {
            Section {
                header
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }

            // Playlist order is the server's order; never re-sorted.
            ForEach(Array(songs.enumerated()), id: \.offset) { index, _ in
                PlayableSongRow(
                    songs: songs, index: index, source: playlist.name, selection: selection
                )
                    // Trailing swipe removes from the playlist here, rather than the
                    // generic "add to queue": in a playlist, removal is the action you
                    // actually want, and the index is valid because `songs` came
                    // straight from the server.
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button(role: .destructive) {
                            Task {
                                if await store.removeIndex(index, from: playlist.id) {
                                    await load()
                                }
                            }
                        } label: {
                            Label("Remove", systemImage: "minus.circle")
                        }
                    }
            }
        }
        .listStyle(.plain)
        .collapsingTitle(playlist.name)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                CollectionDownloadButton(
                    songs: songs, groupID: playlist.id, groupName: playlist.name
                )
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("Start Radio", systemImage: "dot.radiowaves.left.and.right") {
                        startRadio()
                    }
                    Button("Select Tracks", systemImage: "checkmark.circle") {
                        selection.begin()
                    }
                    if let match = store.playlists.first(where: { $0.id == playlist.id }) {
                        Divider()
                        Button("Rename…", systemImage: "pencil") { editing = match }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .sheet(item: $editing) { EditPlaylistSheet(playlist: $0) }
        .safeAreaInset(edge: .bottom) {
            if selection.isActive {
                SelectionToolbar(selection: selection, all: songs, source: playlist.name)
            }
        }
        .toolbar {
            if selection.isActive {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { selection.end() }
                }
            }
        }
        .task { await load() }
    }

    private var header: some View {
        VStack(spacing: Metrics.headerToContent) {
            ArtworkImage(
                id: detail?.coverArt ?? playlist.coverArt,
                size: .full,
                cornerRadius: Metrics.radiusHeader
            )
            .aspectRatio(1, contentMode: .fit)
            .frame(maxWidth: Metrics.detailArtwork)
            .shadow(radius: 12, y: 6)

            VStack(spacing: 4) {
                Text(playlist.name)
                    .font(.title2.weight(.bold))
                    .multilineTextAlignment(.center)

                if let comment = detail?.comment, !comment.isEmpty {
                    Text(comment)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }

            PlayShuffleButtons(
                onPlay: {
                    appState.player.play(songs: songs, startingAt: 0, source: playlist.name)
                },
                onShuffle: {
                    appState.player.play(
                        songs: songs, startingAt: 0, source: playlist.name, shuffled: true
                    )
                }
            )
            .padding(.horizontal, Metrics.gutter)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Metrics.gutter)
    }

    @State private var editing: Playlist?

    private var songs: [Song] { detail?.songs ?? [] }

    /// Seeded from a random track in the playlist, so the mix differs each time rather
    /// than always radiating out from track one.
    private func startRadio() {
        guard let seed = songs.randomElement() else { return }
        Task {
            let mix = await appState.radio.mix(seed: seed, scope: scope.scope)
            appState.startRadio(named: "\(playlist.name) Radio", songs: mix)
        }
    }

    private var subtitle: String {
        var parts: [String] = []
        if let count = detail?.songCount { parts.append("\(count) songs") }
        if let duration = detail?.duration { parts.append(duration.asLongDuration) }
        return parts.joined(separator: " · ")
    }

    private func load() async {
        let id = playlist.id
        detail = await appState.cached(CacheKey.playlist(id)) { [client = appState.client] in
            try await client.playlistDetail(id: id)
        }
    }
}
