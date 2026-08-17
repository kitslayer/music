import SwiftUI

/// A `ScrollView` rather than a `List`, because the content is heterogeneous --
/// header, buttons, a top-songs block, then album rows -- and forcing that into a
/// List fights it.
struct ArtistDetailView: View {
    @Environment(AppState.self) private var appState

    let artist: ArtistRef

    @State private var detail: ArtistDetail?
    @State private var topSongs: [Song] = []

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

                        ForEach(topSongs) { song in
                            SongRow(song: song, style: .withArtwork)
                                .padding(.horizontal, Metrics.gutter)
                                .padding(.vertical, 6)
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

            PlayShuffleButtons(onPlay: {}, onShuffle: {})
                .padding(.horizontal, Metrics.gutter)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, Metrics.gutter)
    }

    private func load() async {
        detail = try? await appState.client.artistDetail(id: artist.id)
        topSongs = (try? await appState.client.topSongs(artist: artist.name)) ?? []
    }
}
