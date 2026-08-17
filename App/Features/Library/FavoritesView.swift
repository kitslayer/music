import SwiftUI

struct FavoritesView: View {
    @Environment(AppState.self) private var appState
    @Environment(LibraryScopeStore.self) private var scope

    @State private var starred: Starred2?
    @State private var isLoading = false

    var body: some View {
        List {
            if let albums = starred?.albums, !albums.isEmpty {
                Section("Albums") {
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
                                    Text(album.name).lineLimit(1)
                                    if let artist = album.artist {
                                        Text(artist)
                                            .font(.footnote)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                }
                            }
                        }
                    }
                }
            }

            if let songs = starred?.songs, !songs.isEmpty {
                Section("Songs") {
                    ForEach(songs) { song in
                        SongRow(song: song, style: .withArtwork)
                    }
                }
            }
        }
        .listStyle(.plain)
        .navigationTitle("Favourites")
        .overlay {
            if isLoading, starred == nil { ProgressView() }
        }
        .overlay {
            if !isLoading, starred?.songs.isEmpty == true, starred?.albums.isEmpty == true {
                ContentUnavailableView(
                    "No Favourites",
                    systemImage: "star",
                    description: Text("Starred songs and albums appear here.")
                )
            }
        }
        .refreshable { await load() }
        .task(id: scope.generation) { await load() }
    }

    private func load() async {
        isLoading = true
        starred = try? await appState.client.starred(scope: scope.scope)
        isLoading = false
    }
}
