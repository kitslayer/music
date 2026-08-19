import Foundation
import Observation

/// Keeps playlists on the phone automatically.
///
/// On by default, for every playlist, because the whole reason this app exists is that
/// offline music was paywalled elsewhere — so the sensible default is "it's already
/// there" rather than "remember to press download".
///
/// Two guard rails, because "download everything" is a big promise on a phone:
///
/// - **Wi-Fi only by default.** 499 tracks of FLAC is roughly 20 GB; that is not
///   something to put on a cellular bill by accident.
/// - **It only ever adds.** A track dropped from a playlist keeps its download rather
///   than being deleted, because the alternative is an automatic process quietly
///   removing music someone may have wanted. Reclaiming space stays a manual choice in
///   the Downloads screen.
@MainActor
@Observable
final class PlaylistSync {
    private enum Key {
        static let enabled = "playlistSync.enabled"
        static let wifiOnly = "playlistSync.wifiOnly"
        static let excluded = "playlistSync.excludedIDs"
        static let favourites = "playlistSync.favourites"
    }

    /// Default **on**: everything is kept offline unless told otherwise.
    var isEnabled: Bool {
        didSet { UserDefaults.standard.set(isEnabled, forKey: Key.enabled) }
    }

    var isWiFiOnly: Bool {
        didSet { UserDefaults.standard.set(isWiFiOnly, forKey: Key.wifiOnly) }
    }

    /// Starred songs are kept too, by the same argument as playlists: they are the
    /// tracks singled out as worth keeping, so "already there" is the right default.
    var includesFavourites: Bool {
        didSet { UserDefaults.standard.set(includesFavourites, forKey: Key.favourites) }
    }

    /// Playlists deliberately left out. Stored as ids so renaming one keeps the choice.
    private(set) var excludedIDs: Set<String> {
        didSet {
            UserDefaults.standard.set(Array(excludedIDs), forKey: Key.excluded)
        }
    }

    private(set) var isSyncing = false
    /// Last thing it did, for the settings screen.
    private(set) var lastSummary: String?

    private weak var client: SubsonicClient?
    private weak var downloads: DownloadCenter?
    private weak var reachability: Reachability?

    init() {
        let defaults = UserDefaults.standard
        // `object(forKey:)` rather than `bool(forKey:)`, because a missing key has to
        // mean "on" here and `bool` would report false.
        isEnabled = defaults.object(forKey: Key.enabled) as? Bool ?? true
        isWiFiOnly = defaults.object(forKey: Key.wifiOnly) as? Bool ?? true
        includesFavourites = defaults.object(forKey: Key.favourites) as? Bool ?? true
        excludedIDs = Set(defaults.stringArray(forKey: Key.excluded) ?? [])
    }

    func configure(
        client: SubsonicClient,
        downloads: DownloadCenter,
        reachability: Reachability
    ) {
        self.client = client
        self.downloads = downloads
        self.reachability = reachability
    }

    func isIncluded(_ playlist: Playlist) -> Bool {
        isEnabled && !excludedIDs.contains(playlist.id)
    }

    func setIncluded(_ included: Bool, for playlist: Playlist) {
        if included {
            excludedIDs.remove(playlist.id)
        } else {
            excludedIDs.insert(playlist.id)
        }
    }

    /// Fetches every included playlist and queues anything not already on the phone.
    ///
    /// Safe to call often: it compares against the download catalog first, so a synced
    /// library makes this a handful of cheap requests and no transfers.
    func sync() async {
        guard isEnabled, !isSyncing,
              let client, let downloads
        else { return }

        if isWiFiOnly, reachability?.isExpensive == true {
            lastSummary = "Waiting for Wi-Fi"
            return
        }
        guard reachability?.isOnline != false else { return }

        isSyncing = true
        defer { isSyncing = false }

        guard let playlists = try? await client.playlists() else { return }

        var queued = 0
        for playlist in playlists where !excludedIDs.contains(playlist.id) {
            guard let detail = try? await client.playlistDetail(id: playlist.id) else { continue }

            let missing = detail.songs.filter { downloads.status(for: $0.id) == .none }
            guard !missing.isEmpty else { continue }

            // Grouped under the playlist so the Downloads screen shows why they are
            // here, and removing the group removes the lot.
            downloads.download(missing, groupID: playlist.id, groupName: playlist.name)
            queued += missing.count
        }

        if includesFavourites, let starred = try? await client.starred() {
            let missing = starred.songs.filter { downloads.status(for: $0.id) == .none }
            if !missing.isEmpty {
                // Their own group, so removing "Favourites" from Downloads does not
                // take a playlist's copies with it.
                downloads.download(missing, groupID: "favourites", groupName: "Favourites")
                queued += missing.count
            }
        }

        lastSummary = queued == 0
            ? "Everything is on this phone"
            : "Downloading \(queued) \(queued == 1 ? "track" : "tracks")"

        if queued > 0 {
            await Diagnostics.shared.record("playlist sync", "queued \(queued) tracks")
        }
    }

    /// Rough projection for the settings screen, so 20 GB is never a surprise.
    ///
    /// Uses the playlists' own reported durations rather than fetching every track, and
    /// the rate measured from the files already on the phone rather than the 1 MB/s this
    /// used to assume — that figure is only correct for 16-bit 44.1 kHz FLAC.
    func estimatedSize(for playlists: [Playlist], bytesPerSecond: Double = 1_000_000) -> Int64 {
        let seconds = playlists
            .filter { !excludedIDs.contains($0.id) }
            .reduce(0) { $0 + ($1.duration ?? 0) }
        return Int64(Double(seconds) * bytesPerSecond)
    }
}
