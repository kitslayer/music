import SwiftUI

/// A `ScrollView` rather than a `List`, because the content is heterogeneous --
/// header, buttons, a top-songs block, then album rows -- and forcing that into a
/// List fights it.
struct ArtistDetailView: View {
    @Environment(AppState.self) private var appState
    @Environment(LibraryScopeStore.self) private var scope

    let artist: ArtistRef

    @State private var detail: ArtistDetail?
    @State private var topSongs: [Song] = []
    /// Every track by the artist, in album order. Loaded lazily by Play/Shuffle
    /// because it costs one request per album and most visits never press either.
    @State private var isGatheringDiscography = false

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Metrics.shelfSpacing) {
                header

                // Omitted entirely when empty: Navidrome without a Last.fm key
                // returns nothing here, and an empty section looks broken.
                if !topSongs.isEmpty {
                    VStack(alignment: .leading, spacing: Metrics.headerToContent) {
                        Text("Top Songs")
                            .font(.title3.weight(.semibold))
                            .padding(.horizontal, Metrics.gutter)

                        ForEach(Array(topSongs.enumerated()), id: \.element.id) { index, song in
                            Button {
                                appState.player.play(
                                    songs: topSongs, startingAt: index, source: artist.name
                                )
                            } label: {
                                SongRow(
                                    song: song,
                                    style: .withArtwork,
                                    isCurrent: appState.player.currentSong?.id == song.id
                                )
                                .padding(.horizontal, Metrics.gutter)
                                .padding(.vertical, 6)
                            }
                            .buttonStyle(.plain)
                            .contextMenu { SongMenu(song: song, showsNavigation: false) }
                        }
                    }
                }

                if let albums = detail?.albums, !albums.isEmpty {
                    VStack(alignment: .leading, spacing: Metrics.headerToContent) {
                        Text("Albums")
                            .font(.title3.weight(.semibold))
                            .padding(.horizontal, Metrics.gutter)

                        // Rows, not a grid: denser and more scannable for the
                        // 1-30 albums an artist actually has.
                        ForEach(albums) { album in
                            NavigationLink(value: Destination.album(AlbumRef(album))) {
                                HStack(spacing: Metrics.itemSpacing) {
                                    ArtworkImage(
                                        id: album.coverArt,
                                        size: .thumb,
                                        cornerRadius: Metrics.radiusThumb
                                    )
                                    .frame(width: Metrics.thumbRow, height: Metrics.thumbRow)

                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(album.name)
                                            .lineLimit(1)
                                            .foregroundStyle(.primary)
                                        if let year = album.year {
                                            Text(String(year))
                                                .font(.footnote)
                                                .foregroundStyle(.secondary)
                                        }
                                    }

                                    Spacer(minLength: 8)

                                    Image(systemName: "chevron.right")
                                        .font(.caption)
                                        .foregroundStyle(.tertiary)
                                }
                                .padding(.horizontal, Metrics.gutter)
                                .frame(minHeight: 60)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .padding(.bottom, 24)
        }
        .collapsingTitle(artist.name)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                FavoriteButton(
                    id: artist.id,
                    kind: .artist,
                    serverValue: detail?.starred != nil
                )
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    startArtistRadio()
                } label: {
                    Image(systemName: "dot.radiowaves.left.and.right")
                }
                .disabled(isGatheringDiscography)
                .accessibilityLabel("Start artist radio")
            }
        }
        .task { await load() }
    }

    private var header: some View {
        VStack(spacing: Metrics.headerToContent) {
            ArtistArtwork(
                id: detail?.coverArt ?? artist.coverArt,
                diameter: 112,
                initials: artist.name.monogram
            )

            VStack(spacing: 4) {
                Text(artist.name)
                    .font(.title2.weight(.bold))
                    .multilineTextAlignment(.center)

                if let count = detail?.albumCount {
                    Text("\(count) albums")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            PlayShuffleButtons(
                onPlay: { playDiscography(shuffled: false) },
                onShuffle: { playDiscography(shuffled: true) },
                isBusy: isGatheringDiscography
            )
            .padding(.horizontal, Metrics.gutter)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, Metrics.gutter)
    }

    /// Albums are fetched concurrently but the result is assembled in release order,
    /// so "Play" starts with the earliest record rather than whichever request
    /// happened to answer first.
    private func playDiscography(shuffled: Bool) {
        guard !isGatheringDiscography, let albums = detail?.albums, !albums.isEmpty else { return }
        isGatheringDiscography = true

        Task {
            let ordered = albums.sorted { ($0.year ?? 0) < ($1.year ?? 0) }
            var byAlbum: [String: [Song]] = [:]

            await withTaskGroup(of: (String, [Song]).self) { group in
                for album in ordered {
                    group.addTask { [client = appState.client] in
                        let detail = try? await client.albumDetail(id: album.id)
                        return (album.id, detail?.songs ?? [])
                    }
                }
                for await (id, songs) in group {
                    byAlbum[id] = songs
                }
            }

            let songs = ordered.flatMap { byAlbum[$0.id] ?? [] }
            isGatheringDiscography = false
            guard !songs.isEmpty else { return }

            appState.player.play(
                songs: songs, startingAt: 0, source: artist.name, shuffled: shuffled
            )
        }
    }

    /// Reuses the same busy flag as Play/Shuffle: both walk every album, and showing
    /// two independent spinners for one kind of work would be noise.
    private func startArtistRadio() {
        guard !isGatheringDiscography else { return }
        isGatheringDiscography = true
        Task {
            let mix = await appState.radio.artistMix(artist, scope: scope.scope)
            isGatheringDiscography = false
            appState.startRadio(named: "\(artist.name) Radio", songs: mix)
        }
    }

    private func load() async {
        detail = try? await appState.client.artistDetail(id: artist.id)
        topSongs = (try? await appState.client.topSongs(artist: artist.name)) ?? []
    }
}
