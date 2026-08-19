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
                .swipeActions(edge: .leading, allowsFullSwipe: true) {
                    Button {
                        startGenreRadio(genre.value)
                    } label: {
                        Label("Radio", systemImage: "dot.radiowaves.left.and.right")
                    }
                    .tint(.appTint)
                }
                .contextMenu {
                    Button("Genre Radio", systemImage: "dot.radiowaves.left.and.right") {
                        startGenreRadio(genre.value)
                    }
                }
            }
        }
        .listStyle(.plain)
        .navigationTitle("Genres")
        .refreshable { await load() }
        .task(id: scope.generation) { await load() }
    }

    /// A random draw within the genre, which the server supports directly -- so this
    /// is genuinely "genre radio" rather than a shuffle of a fixed page of results.
    private func startGenreRadio(_ genre: String) {
        Task {
            let mix = await appState.radio.genreMix(genre, scope: scope.scope)
            appState.startRadio(named: "\(genre) Radio", songs: mix)
        }
    }

    private func load() async {
        // Sorted by album count: 366 genres alphabetically is a wall of noise,
        // while the largest genres are what you actually browse.
        let client = appState.client
        let currentScope = scope.scope
        appState.beginLoadPass()
        let fetched: [Genre] = await appState.cached(
            CacheKey.genres(currentScope.cacheKey)
        ) {
            try await client.genres(scope: currentScope)
        } ?? []
        genres = fetched
            .sorted { ($0.albumCount ?? 0) > ($1.albumCount ?? 0) }
    }
}

/// Reuses the album grid, scoped to one genre.
struct GenreDetailView: View {
    @Environment(AppState.self) private var appState
    @Environment(LibraryScopeStore.self) private var scope

    let genre: String

    var body: some View {
        AlbumListView(genre: genre)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task {
                            let mix = await appState.radio.genreMix(genre, scope: scope.scope)
                            appState.startRadio(named: "\(genre) Radio", songs: mix)
                        }
                    } label: {
                        Image(systemName: "dot.radiowaves.left.and.right")
                    }
                    .accessibilityLabel("Genre radio")
                }
            }
    }
}
