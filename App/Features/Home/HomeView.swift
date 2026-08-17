import SwiftUI

struct HomeView: View {
    @Environment(AppState.self) private var appState
    @Environment(LibraryScopeStore.self) private var scope

    @State private var model = HomeModel()

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Metrics.shelfSpacing) {
                    if model.isEmpty, model.hasLoaded {
                        ContentUnavailableView {
                            Label("Nothing to show", systemImage: "music.note.house")
                        } description: {
                            Text("Couldn't reach the server, or the library is empty.")
                        } actions: {
                            Button("Try again") {
                                Task { await model.load(client: appState.client, scope: scope.scope) }
                            }
                        }
                        .padding(.top, 60)
                    } else {
                        albumShelf("Recently Played", model.recentlyPlayed, sort: .recent)
                        albumShelf("Recently Added", model.recentlyAdded, sort: .newest)
                        favoriteSongs
                        albumShelf("Most Played", model.mostPlayed, sort: .frequent)
                    }
                }
                .padding(.vertical, Metrics.itemSpacing)
            }
            .navigationTitle("Home")
            .musicDestinations()
            .offlineBanner()
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task {
                            let songs = (try? await appState.client.randomSongs(
                                size: 100, scope: scope.scope
                            )) ?? []
                            appState.startRadio(named: "Shuffle", songs: songs)
                        }
                    } label: {
                        Image(systemName: "shuffle")
                    }
                    .accessibilityLabel("Shuffle library")
                }
                ToolbarItem(placement: .topBarTrailing) { LibraryScopeMenu() }
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink(value: Destination.settings) {
                        Image(systemName: "gearshape")
                    }
                }
            }
            .refreshable {
                await model.load(client: appState.client, scope: scope.scope)
            }
            .task(id: scope.generation) {
                await model.load(client: appState.client, scope: scope.scope)
            }
        }
    }

    @ViewBuilder
    private func albumShelf(_ title: String, _ albums: [Album], sort: AlbumSort) -> some View {
        if !albums.isEmpty {
            VStack(alignment: .leading, spacing: Metrics.headerToContent) {
                ShelfHeader(title: title, seeAll: .albums(sort))

                ScrollView(.horizontal) {
                    LazyHStack(spacing: Metrics.itemSpacing) {
                        ForEach(albums) { album in
                            NavigationLink(value: Destination.album(AlbumRef(album))) {
                                AlbumCard(album: album)
                                    .frame(width: Metrics.cardWidth)
                            }
                            .buttonStyle(.plain)
                            .albumMenu(album)
                        }
                    }
                    .scrollTargetLayout()
                }
                .scrollTargetBehavior(.viewAligned)
                .contentMargins(.horizontal, Metrics.gutter, for: .scrollContent)
                .scrollIndicators(.hidden)
            }
        }
    }

    /// Deliberately vertical: it breaks the carousel rhythm, and it is the only
    /// shelf you can act on without a second tap.
    @ViewBuilder
    private var favoriteSongs: some View {
        if !model.favoriteSongs.isEmpty {
            VStack(alignment: .leading, spacing: Metrics.headerToContent) {
                ShelfHeader(title: "Favourites", seeAll: .favorites)

                VStack(spacing: 0) {
                    ForEach(model.favoriteSongs) { song in
                        SongRow(song: song, style: .withArtwork)
                            .padding(.horizontal, Metrics.gutter)
                            .padding(.vertical, 6)
                            .contentShape(Rectangle())
                    }
                }
            }
        }
    }
}

struct ShelfHeader: View {
    let title: String
    var seeAll: Destination?

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.title3.weight(.semibold))
            Spacer()
            if let seeAll {
                NavigationLink(value: seeAll) {
                    Text("See All")
                        .font(.subheadline)
                }
            }
        }
        .padding(.horizontal, Metrics.gutter)
    }
}

@MainActor
@Observable
final class HomeModel {
    var recentlyPlayed: [Album] = []
    var recentlyAdded: [Album] = []
    var mostPlayed: [Album] = []
    var favoriteSongs: [Song] = []
    var hasLoaded = false

    var isEmpty: Bool {
        recentlyPlayed.isEmpty && recentlyAdded.isEmpty
            && mostPlayed.isEmpty && favoriteSongs.isEmpty
    }

    /// Shelves load concurrently and a failing shelf is simply dropped: one dead
    /// endpoint should not replace the whole screen with an error.
    func load(client: SubsonicClient, scope: LibraryScope) async {
        async let played = try? client.albums(type: .recent, size: 12, scope: scope)
        async let added = try? client.albums(type: .newest, size: 12, scope: scope)
        async let frequent = try? client.albums(type: .frequent, size: 12, scope: scope)
        async let starred = try? client.starred(scope: scope)

        recentlyPlayed = await played ?? []
        recentlyAdded = await added ?? []
        mostPlayed = await frequent ?? []
        favoriteSongs = Array((await starred?.songs ?? []).prefix(4))
        hasLoaded = true
    }
}
