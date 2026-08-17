import SwiftUI

/// Everything that can be pushed. Registered once per `NavigationStack` via
/// `.musicDestinations()`.
enum Destination: Hashable {
    case album(AlbumRef)
    case artist(ArtistRef)
    case playlist(PlaylistRef)
    case genre(String)
    case albums(AlbumSort)
    case artists
    case playlists
    case genres
    case favorites
    case downloads
    case settings
    case audioSettings
    case requestMusic(String)
    case requestSettings
    case offlineSettings
    case diagnostics
}

extension View {
    /// Attach to the root container **inside** each `NavigationStack`, exactly once.
    ///
    /// Placing `navigationDestination` inside a lazy container (a `LazyVGrid` cell or
    /// a `List` row) is the classic bug: the modifier is not registered until that
    /// row materialises, so links from rows that scrolled past silently do nothing.
    func musicDestinations() -> some View {
        navigationDestination(for: Destination.self) { destination in
            switch destination {
            case let .album(ref):
                AlbumDetailView(album: ref)
            case let .artist(ref):
                ArtistDetailView(artist: ref)
            case let .playlist(ref):
                PlaylistDetailView(playlist: ref)
            case let .genre(name):
                GenreDetailView(genre: name)
            case let .albums(sort):
                AlbumListView(initialSort: sort)
            case .artists:
                ArtistListView()
            case .playlists:
                PlaylistListView()
            case .genres:
                GenreListView()
            case .favorites:
                FavoritesView()
            case .downloads:
                DownloadsView()
            case .settings:
                SettingsView()
            case .audioSettings:
                AudioSettingsView()
            case let .requestMusic(prefill):
                MusicRequestView(initialText: prefill)
            case .requestSettings:
                MusicRequestSettingsView()
            case .offlineSettings:
                OfflineSettingsView()
            case .diagnostics:
                DiagnosticsView()
            }
        }
    }
}
