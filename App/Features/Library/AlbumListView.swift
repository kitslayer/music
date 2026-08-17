import SwiftUI

struct AlbumListView: View {
    @Environment(AppState.self) private var appState

    @State private var albums: [Album] = []
    @State private var sort: AlbumSort = .newest
    @State private var error: String?
    @State private var isLoading = false

    private let columns = [GridItem(.adaptive(minimum: 150, maximum: 220), spacing: 16)]

    var body: some View {
        NavigationStack {
            ScrollView {
                if let error {
                    ContentUnavailableView {
                        Label("Can't load albums", systemImage: "wifi.exclamationmark")
                    } description: {
                        Text(error)
                    } actions: {
                        Button("Try again") { Task { await load() } }
                    }
                    .padding(.top, 60)
                } else {
                    LazyVGrid(columns: columns, spacing: 20) {
                        ForEach(albums) { album in
                            NavigationLink(value: album) {
                                AlbumCard(album: album)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 24)
                }
            }
            .navigationTitle("Albums")
            .navigationDestination(for: Album.self) { album in
                AlbumDetailView(album: album)
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Picker("Sort", selection: $sort) {
                            ForEach(AlbumSort.allCases) { option in
                                Text(option.title).tag(option)
                            }
                        }
                    } label: {
                        Image(systemName: "arrow.up.arrow.down")
                    }
                }
            }
            .overlay {
                if isLoading, albums.isEmpty {
                    ProgressView()
                }
            }
            .refreshable { await load() }
            .task(id: sort) { await load() }
        }
    }

    private func load() async {
        isLoading = true
        do {
            albums = try await appState.client.albums(type: sort, size: 200)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
        isLoading = false
    }
}

struct AlbumCard: View {
    @Environment(AppState.self) private var appState
    let album: Album

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            CoverArt(id: album.coverArt, size: 400)
                .aspectRatio(1, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 8))

            Text(album.name)
                .font(.subheadline.weight(.medium))
                .lineLimit(1)

            if let artist = album.artist {
                Text(artist)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }
}

/// Cover art loader. `AsyncImage` is enough here: the URL carries its own auth,
/// and URLSession's cache handles repeat views without a bespoke image cache.
struct CoverArt: View {
    @Environment(AppState.self) private var appState
    let id: String?
    var size: Int?

    @State private var url: URL?

    var body: some View {
        AsyncImage(url: url) { phase in
            switch phase {
            case let .success(image):
                image.resizable()
            default:
                Rectangle()
                    .fill(.quaternary)
                    .overlay {
                        Image(systemName: "music.note")
                            .foregroundStyle(.secondary)
                    }
            }
        }
        .task(id: id) {
            url = await appState.client.coverArtURL(for: id, size: size)
        }
    }
}
