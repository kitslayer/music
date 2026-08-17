import SwiftUI

/// The hub. Six peer facets is exactly the case a tab bar cannot hold, which is why
/// Apple Music uses a list here too.
struct LibraryHubView: View {
    @Environment(AppState.self) private var appState
    @Environment(LibraryScopeStore.self) private var scope
    @Environment(DownloadCenter.self) private var downloads

    @State private var recentlyAdded: [Album] = []

    private let gridColumns = [
        GridItem(.flexible(), spacing: Metrics.itemSpacing),
        GridItem(.flexible(), spacing: Metrics.itemSpacing),
    ]

    var body: some View {
        NavigationStack {
            List {
                Section {
                    row("Playlists", "music.note.list", .playlists)
                    row("Artists", "music.microphone", .artists)
                    row("Albums", "square.stack", .albums(.alphabeticalByName))
                    row("Genres", "guitars", .genres)
                    row("Favourites", "star", .favorites)
                    // The one row whose contents live on this phone, so it is the
                    // one row where a count says something the screen does not.
                    row(
                        "Downloads",
                        "arrow.down.circle",
                        .downloads,
                        badge: downloads.catalog.entries.isEmpty
                            ? nil
                            : "\(downloads.catalog.entries.count)"
                    )
                    row("Request Music", "arrow.down.heart", .requestMusic(""))
                    row("Settings", "gearshape", .settings)
                }

                if !recentlyAdded.isEmpty {
                    Section {
                        // A grid inside a List works reliably as long as the row's
                        // insets and background are cleared.
                        LazyVGrid(columns: gridColumns, spacing: Metrics.itemSpacing) {
                            ForEach(recentlyAdded) { album in
                                NavigationLink(value: Destination.album(AlbumRef(album))) {
                                    AlbumCard(album: album)
                                }
                                .buttonStyle(.plain)
                                .albumMenu(album)
                            }
                        }
                        .listRowInsets(EdgeInsets(
                            top: 8, leading: Metrics.gutter,
                            bottom: 8, trailing: Metrics.gutter
                        ))
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                    } header: {
                        HStack {
                            Text("Recently Added")
                            Spacer()
                            NavigationLink(value: Destination.albums(.newest)) {
                                Text("See All").font(.footnote)
                            }
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .listSectionSpacing(.compact)
            .navigationTitle("Library")
            .musicDestinations()
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { LibraryScopeMenu() }
            }
            .task(id: scope.generation) {
                recentlyAdded = (try? await appState.client.albums(
                    type: .newest, size: 6, scope: scope.scope
                )) ?? []
            }
        }
    }

    private func row(
        _ title: String,
        _ symbol: String,
        _ destination: Destination,
        badge: String? = nil
    ) -> some View {
        NavigationLink(value: destination) {
            Label {
                Text(title)
            } icon: {
                Image(systemName: symbol)
                    .foregroundStyle(Color.appTint)
                    // Fixed icon width so every title shares a left edge.
                    .frame(width: 28, alignment: .center)
            }
        }
        .badge(badge)
        .frame(minHeight: Metrics.rowCategory)
    }
}
