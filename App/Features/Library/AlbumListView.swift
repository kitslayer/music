import SwiftUI

struct AlbumListView: View {
    @Environment(AppState.self) private var appState
    @Environment(LibraryScopeStore.self) private var scope

    var initialSort: AlbumSort = .newest
    /// Set when this list is a genre drill-down.
    var genre: String?

    @State private var albums: [Album] = []
    @State private var sort: AlbumSort = .newest
    @State private var error: String?
    @State private var isLoadingPage = false
    @State private var canLoadMore = true
    @State private var didApplyInitialSort = false

    /// Fixed two columns: the app is portrait-only, so `.adaptive` buys nothing and
    /// costs a stable grid.
    private let columns = [
        GridItem(.flexible(), spacing: Metrics.itemSpacing),
        GridItem(.flexible(), spacing: Metrics.itemSpacing),
    ]

    private var pageSize: Int { 100 }

    var body: some View {
        ScrollView {
            if let error, albums.isEmpty {
                ContentUnavailableView {
                    Label("Can't load albums", systemImage: "wifi.exclamationmark")
                } description: {
                    Text(error)
                } actions: {
                    Button("Try again") { Task { await reload() } }
                }
                .padding(.top, 60)
            } else {
                LazyVGrid(columns: columns, spacing: 20) {
                    ForEach(albums) { album in
                        NavigationLink(value: Destination.album(AlbumRef(album))) {
                            AlbumCard(album: album)
                        }
                        .buttonStyle(.plain)
                        .albumMenu(album)
                    }
                }
                .padding(.horizontal, Metrics.gutter)

                // A sentinel rather than scroll-offset maths: `.task` on a lazily
                // created view is cancellation-correct and fires exactly when the
                // user reaches the end.
                if canLoadMore, !albums.isEmpty {
                    ProgressView()
                        .padding(.vertical, 24)
                        .task { await loadMore() }
                }
            }
        }
        .navigationTitle(genre ?? "Albums")
        .toolbar {
            if genre == nil {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Picker("Sort", selection: $sort) {
                            ForEach(AlbumSort.allCases) { option in
                                Text(option.title).tag(option)
                            }
                        }
                    } label: {
                        // Show the current sort as text: a bare glyph hides state.
                        Label(sort.title, systemImage: "arrow.up.arrow.down")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) { LibraryScopeMenu() }
            }
        }
        .overlay {
            if isLoadingPage, albums.isEmpty { ProgressView() }
        }
        .refreshable { await reload() }
        .task(id: LoadKey(sort: sort, scope: scope.generation, genre: genre)) {
            if !didApplyInitialSort {
                sort = initialSort
                didApplyInitialSort = true
            }
            await reload()
        }
    }

    private struct LoadKey: Equatable {
        let sort: AlbumSort
        let scope: Int
        let genre: String?
    }

    private func reload() async {
        albums = []
        canLoadMore = true
        await loadMore()
    }

    private func loadMore() async {
        guard !isLoadingPage, canLoadMore else { return }
        isLoadingPage = true

        do {
            let offset = albums.count
            let currentSort = sort
            let currentGenre = genre
            let currentScope = scope.scope
            let client = appState.client

            // Only the first page is cached: offline, page 0 is the whole useful answer,
            // and stitching later pages into one entry buys nothing for the complexity.
            let page: [Album]
            if offset == 0, currentGenre == nil {
                appState.beginLoadPass()
                let cached: [Album]? = await appState.cached(
                    CacheKey.albumList(currentSort.rawValue, currentScope.cacheKey)
                ) {
                    try await client.albums(
                        type: currentSort, size: 100, offset: 0, scope: currentScope
                    )
                }
                guard let cached else { throw SubsonicClient.ClientError.notConfigured }
                page = cached
            } else {
                page = try await client.albums(
                    type: currentSort,
                    size: pageSize,
                    offset: offset,
                    scope: currentScope,
                    genre: currentGenre
                )
            }
            albums.append(contentsOf: page)
            // A short page means the end. `random` never terminates meaningfully,
            // so stop after one page rather than looping forever.
            canLoadMore = page.count == pageSize && sort != .random
            error = nil
        } catch {
            self.error = error.localizedDescription
            canLoadMore = false
        }

        isLoadingPage = false
    }
}
