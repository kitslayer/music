import SwiftUI

/// A `ScrollView` rather than a `List`, because the content is heterogeneous --
/// header, buttons, a top-songs block, then album rows -- and forcing that into a
/// List fights it.
struct ArtistDetailView: View {
    @Environment(AppState.self) private var appState
    @Environment(LibraryScopeStore.self) private var scope

    let artist: ArtistRef

    @State private var detail: ArtistDetail?
    /// The artist's whole catalogue, most played first. `getTopSongs` is not used: it only
    /// knows tracks that have been played, so it answers with a handful for a familiar
    /// artist and *one* for Nirvana. Sorting the catalogue by the server's own play counts —
    /// which include everything imported from Plex — gives a real popularity order of any
    /// length, and leaves unplayed artists in album order rather than empty.
    @State private var popular: [Song] = []
    @State private var isGatheringDiscography = false
    /// Ten is what every other player shows here. The rest are one tap away rather than a
    /// screen away, because a 200-track wall would bury the Albums section underneath it.
    @State private var showsAllPopular = false

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Metrics.shelfSpacing) {
                header

                if !popular.isEmpty {
                    VStack(alignment: .leading, spacing: Metrics.headerToContent) {
                        Text("Popular")
                            .font(.title3.weight(.semibold))
                            .padding(.horizontal, Metrics.gutter)

                        // `PlayableSongRow`, so a tap plays the list from that point and the
                        // menu, star, rating and download all come free — the hand-rolled
                        // Button/SongRow pair this replaces had only tap-to-play.
                        // The row's index is into the *whole* ordered list, so tapping the
                        // third one plays from there through everything below it in
                        // popularity order — collapsed or not.
                        ForEach(Array(visiblePopular.enumerated()), id: \.offset) { index, _ in
                            PlayableSongRow(
                                songs: popular,
                                index: index,
                                source: artist.name,
                                showsNavigation: false
                            )
                            .padding(.horizontal, Metrics.gutter)
                            .padding(.vertical, 6)
                        }

                        if popular.count > Self.collapsedPopularCount {
                            Button {
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    showsAllPopular.toggle()
                                }
                            } label: {
                                Label(
                                    showsAllPopular
                                        ? "Show less"
                                        : "Show all \(popular.count) songs",
                                    systemImage: showsAllPopular ? "chevron.up" : "chevron.down"
                                )
                                .font(.subheadline.weight(.medium))
                                .padding(.horizontal, Metrics.gutter)
                                .padding(.vertical, 8)
                            }
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

            // Where a biography would go if the server had one. It does not: this
            // server's `getArtistInfo2` returns no text at all and its image URLs 404.
            HermesNoteSection(
                subject: .artist(id: artist.id, name: artist.name),
                isCompact: true
            )
            .padding(.horizontal, Metrics.gutter)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, Metrics.gutter)
    }

    static let collapsedPopularCount = 10

    private var visiblePopular: [Song] {
        showsAllPopular ? popular : Array(popular.prefix(Self.collapsedPopularCount))
    }

    /// Plays the catalogue already in hand. It used to gather every album on the spot —
    /// the same requests the Popular list now makes on load — so pressing Play meant
    /// waiting for a fetch that had already happened.
    private func playDiscography(shuffled: Bool) {
        guard !popular.isEmpty else { return }
        appState.player.play(
            songs: popular, startingAt: 0, source: artist.name, shuffled: shuffled
        )
    }

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

        isGatheringDiscography = true
        defer { isGatheringDiscography = false }

        // Cached, so a second visit is instant and an artist page still fills in offline —
        // it costs one request per album, which is the price of a real popularity order.
        let client = appState.client
        let id = artist.id
        let songs: [Song]? = await appState.cached(CacheKey.artistSongs(id)) {
            try await client.artistSongs(id: id)
        }
        popular = Self.byPopularity(songs ?? [])
    }

    /// Most played first. Ties — which is *everything* for an artist that has never been
    /// played — keep the catalogue's own release-then-track order, so the list is stable
    /// between visits instead of reshuffling.
    static func byPopularity(_ songs: [Song]) -> [Song] {
        songs.enumerated()
            .sorted { left, right in
                let a = left.element.playCount ?? 0
                let b = right.element.playCount ?? 0
                return a == b ? left.offset < right.offset : a > b
            }
            .map(\.element)
    }
}
