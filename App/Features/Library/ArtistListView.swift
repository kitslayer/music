import SwiftUI

/// `getArtists` returns the whole indexed list in one call. At 400 artists that is
/// cheap to hold in memory and needs no pagination or index rail.
struct ArtistListView: View {
    @Environment(AppState.self) private var appState
    @Environment(LibraryScopeStore.self) private var scope

    @State private var indexes: [ArtistIndex] = []
    @State private var isLoading = false

    var body: some View {
        ScrollViewReader { proxy in
            list
                .overlay(alignment: .trailing) {
                    if flatArtists.count > 40 {
                        AlphabetRail(available: availableLetters) { letter in
                            guard let target = flatArtists.first(where: {
                                AlphabetRail.bucket(for: $0.name) == letter
                            }) else { return }
                            withAnimation(.easeInOut(duration: 0.2)) {
                                proxy.scrollTo(target.id, anchor: .top)
                            }
                        }
                        .padding(.trailing, 2)
                    }
                }
        }
    }

    private var flatArtists: [Artist] {
        indexes.flatMap(\.artists)
    }

    private var availableLetters: Set<String> {
        Set(flatArtists.map { AlphabetRail.bucket(for: $0.name) })
    }

    private var list: some View {
        List {
            ForEach(indexes) { index in
                Section(index.name) {
                    ForEach(index.artists) { artist in
                        NavigationLink(value: Destination.artist(ArtistRef(artist))) {
                            HStack(spacing: Metrics.itemSpacing) {
                                ArtistArtwork(
                                    id: artist.coverArt,
                                    diameter: 40,
                                    initials: artist.name.monogram
                                )

                                Text(artist.name)
                                    .lineLimit(1)

                                Spacer(minLength: 8)

                                if let count = artist.albumCount {
                                    Text("\(count)")
                                        .font(.footnote.monospacedDigit())
                                        .foregroundStyle(.tertiary)
                                }
                            }
                        }
                        .id(artist.id)
                        .swipeActions(edge: .leading, allowsFullSwipe: true) {
                            FavoriteSwipeButton(
                                id: artist.id, kind: .artist, serverValue: artist.starred != nil
                            )
                        }
                    }
                }
            }
        }
        .listStyle(.plain)
        .navigationTitle("Artists")
        .overlay {
            if isLoading, indexes.isEmpty { ProgressView() }
        }
        .refreshable { await load() }
        .task(id: scope.generation) { await load() }
    }

    private func load() async {
        isLoading = true
        let client = appState.client
        let currentScope = scope.scope
        appState.beginLoadPass()
        indexes = await appState.cached(CacheKey.artistIndex(currentScope.cacheKey)) {
            try await client.artists(scope: currentScope)
        } ?? []
        isLoading = false
    }
}
