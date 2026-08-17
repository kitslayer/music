import SwiftUI

struct GenreListView: View {
    @Environment(AppState.self) private var appState
    @Environment(LibraryScopeStore.self) private var scope

    @State private var genres: [Genre] = []

    var body: some View {
        List {
            ForEach(genres) { genre in
                NavigationLink(value: Destination.genre(genre.value)) {
                    HStack {
                        Text(genre.value)
                        Spacer(minLength: 8)
                        if let count = genre.albumCount {
                            Text("\(count)")
                                .font(.footnote.monospacedDigit())
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .frame(minHeight: Metrics.rowCategory)
                }
            }
        }
        .listStyle(.plain)
        .navigationTitle("Genres")
        .refreshable { await load() }
        .task(id: scope.generation) { await load() }
    }

    private func load() async {
        // Sorted by album count: 366 genres alphabetically is a wall of noise,
        // while the largest genres are what you actually browse.
        genres = ((try? await appState.client.genres(scope: scope.scope)) ?? [])
            .sorted { ($0.albumCount ?? 0) > ($1.albumCount ?? 0) }
    }
}

/// Reuses the album grid, scoped to one genre.
struct GenreDetailView: View {
    let genre: String

    var body: some View {
        AlbumListView(genre: genre)
    }
}
