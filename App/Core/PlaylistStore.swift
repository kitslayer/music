import Foundation
import Observation

/// Playlists, held once for the whole app.
///
/// Not per-view state, for a specific reason: "Add to Playlist" is offered from song
/// rows on six different screens, and each of those would otherwise fetch the playlist
/// list on appear just to populate a menu. One store means the menu is instant, and a
/// playlist created on one screen shows up in the menu on the next.
///
/// Writes go to the server first and the local copy is refreshed from the response.
/// No optimistic editing here, unlike stars: a star is one boolean that is cheap to
/// revert, whereas guessing at playlist contents risks showing a track as added when
/// it was not.
@MainActor
@Observable
final class PlaylistStore {
    private(set) var playlists: [Playlist] = []
    private(set) var isLoading = false
    /// Set after a write so the UI can confirm something happened. Cleared by whoever
    /// shows it.
    var lastMessage: String?

    private weak var client: SubsonicClient?
    private weak var appState: AppState?

    func configure(client: SubsonicClient, appState: AppState) {
        self.client = client
        self.appState = appState
    }

    func reset() {
        playlists = []
        lastMessage = nil
    }

    func load() async {
        guard let client, let appState else { return }
        isLoading = true
        // Cached, so the list is there offline. The tracks themselves are too, because
        // playlists are kept downloaded by default.
        if let fetched: [Playlist] = await appState.cached(CacheKey.playlists, {
            try await client.playlists()
        }) {
            playlists = fetched.sorted {
                $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
        }
        isLoading = false
    }

    /// Loads once. Used by menus, which must not re-fetch every time they open.
    func loadIfNeeded() async {
        guard playlists.isEmpty, !isLoading else { return }
        await load()
    }

    @discardableResult
    func create(name: String, songs: [Song] = []) async -> Playlist? {
        guard let client, !name.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }

        let created = try? await client.createPlaylist(
            name: name.trimmingCharacters(in: .whitespaces),
            songIDs: songs.map(\.id)
        )
        await load()

        if created != nil {
            lastMessage = songs.isEmpty
                ? "Created “\(name)”"
                : "Created “\(name)” with \(songs.count) \(songs.count == 1 ? "song" : "songs")"
        } else {
            lastMessage = "Could not create the playlist"
        }
        return created
    }

    func add(_ songs: [Song], to playlist: Playlist) async {
        guard let client, !songs.isEmpty else { return }
        do {
            try await client.addToPlaylist(id: playlist.id, songIDs: songs.map(\.id))
            lastMessage = songs.count == 1
                ? "Added to “\(playlist.name)”"
                : "Added \(songs.count) songs to “\(playlist.name)”"
            await load()
        } catch {
            lastMessage = "Could not add to “\(playlist.name)”"
        }
    }

    /// The index is a position in the server's current copy, so the caller must have
    /// just fetched it. Returns true so the detail view knows to reload.
    func removeIndex(_ index: Int, from playlistID: String) async -> Bool {
        guard let client else { return false }
        do {
            try await client.removeFromPlaylist(id: playlistID, indices: [index])
            return true
        } catch {
            lastMessage = "Could not remove that track"
            return false
        }
    }

    func rename(_ playlist: Playlist, to name: String, comment: String?) async {
        guard let client, !name.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        do {
            try await client.renamePlaylist(
                id: playlist.id,
                name: name.trimmingCharacters(in: .whitespaces),
                comment: comment
            )
            await load()
        } catch {
            lastMessage = "Could not rename “\(playlist.name)”"
        }
    }

    func delete(_ playlist: Playlist) async {
        guard let client else { return }
        do {
            try await client.deletePlaylist(id: playlist.id)
            lastMessage = "Deleted “\(playlist.name)”"
            await load()
        } catch {
            lastMessage = "Could not delete “\(playlist.name)”"
        }
    }
}
