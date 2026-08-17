import SwiftUI

/// `getArtists` returns the whole indexed list in one call. At 400 artists that is
/// cheap to hold in memory and needs no pagination or index rail.
struct ArtistListView: View {
    @Environment(AppState.self) private var appState
    @Environment(LibraryScopeStore.self) private var scope

    @State private var indexes: [ArtistIndex] = []
    @State private var isLoading = false

    var body: some View {
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
        indexes = (try? await appState.client.artists(scope: scope.scope)) ?? []
        isLoading = false
    }
}
