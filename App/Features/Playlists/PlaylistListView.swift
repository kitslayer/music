import SwiftUI

struct PlaylistListView: View {
    @Environment(AppState.self) private var appState

    @State private var playlists: [Playlist] = []
    @State private var isLoading = false

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
        .overlay {
            if isLoading, playlists.isEmpty { ProgressView() }
        }
        .overlay {
            if !isLoading, playlists.isEmpty {
                ContentUnavailableView(
                    "No Playlists",
                    systemImage: "music.note.list",
                    description: Text("Playlists created on the server appear here.")
                )
            }
        }
        .refreshable { await load() }
        .task { await load() }
    }

    private func subtitle(for playlist: Playlist) -> String {
        var parts: [String] = []
        if let count = playlist.songCount { parts.append("\(count) songs") }
        if let duration = playlist.duration { parts.append(duration.asLongDuration) }
        return parts.joined(separator: " · ")
    }

    private func load() async {
        isLoading = true
        playlists = (try? await appState.client.playlists()) ?? []
        isLoading = false
    }
}

struct PlaylistDetailView: View {
    @Environment(AppState.self) private var appState

    let playlist: PlaylistRef

    @State private var detail: PlaylistDetail?

    var body: some View {
        List {
            Section {
                header
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }

            // Playlist order is the server's order; never re-sorted.
            ForEach(Array(songs.enumerated()), id: \.element.id) { index, _ in
                PlayableSongRow(songs: songs, index: index, source: playlist.name)
            }
        }
        .listStyle(.plain)
        .collapsingTitle(playlist.name)
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

    private var songs: [Song] { detail?.songs ?? [] }

    private var subtitle: String {
        var parts: [String] = []
        if let count = detail?.songCount { parts.append("\(count) songs") }
        if let duration = detail?.duration { parts.append(duration.asLongDuration) }
        return parts.joined(separator: " · ")
    }

    private func load() async {
        detail = try? await appState.client.playlistDetail(id: playlist.id)
    }
}
