import Foundation

/// What is on this phone.
///
/// Plain JSON on disk rather than SwiftData, for one decisive reason: this is written
/// from a background `URLSession` delegate in a process iOS relaunched with no UI,
/// possibly before first unlock. A versioned file that can be dumped, diffed and
/// hand-repaired is worth more than object-graph ergonomics for a couple of thousand
/// rows -- especially with CI as the only compiler and no debugger on the device.
struct DownloadCatalog: Codable, Sendable {
    /// Bumped only for a breaking change; a stale version is discarded rather than
    /// migrated, because the audio files themselves are the real data and can be
    /// re-adopted from disk.
    static let currentVersion = 1

    var version = currentVersion
    /// Keyed by song id.
    var entries: [String: Entry] = [:]
    /// Downloads that have been started but not finished, keyed by song id. Written
    /// **before** the transfer starts, so a kill mid-download leaves enough on disk
    /// to either resume or reconcile.
    var pending: [String: Entry] = [:]

    struct Entry: Codable, Sendable, Identifiable {
        /// The whole song, not a reference: offline browse must not need the server.
        var song: Song
        /// Relative to `Paths.media`, so the container path moving between iOS
        /// versions cannot invalidate the catalog.
        var filename: String
        var byteCount: Int64
        var addedAt: Date
        /// The album or playlist this was downloaded as part of, for grouping in the
        /// Downloads screen. Nil for a single song.
        var groupID: String?
        var groupName: String?

        var id: String { song.id }
        var url: URL { Paths.media.appendingPathComponent(filename) }
    }

    var totalBytes: Int64 {
        entries.values.reduce(0) { $0 + $1.byteCount }
    }
}

/// Owns the catalog file. An actor because the download delegate, the UI and the
/// launch-time reconcile all touch it.
actor DownloadCatalogStore {
    private let url: URL
    private var catalog = DownloadCatalog()
    private var isLoaded = false

    init(url: URL = Paths.catalog) {
        self.url = url
    }

    func load() -> DownloadCatalog {
        guard !isLoaded else { return catalog }
        isLoaded = true

        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(DownloadCatalog.self, from: data),
              decoded.version == DownloadCatalog.currentVersion
        else {
            // Nothing, corrupt, or from a future build: start clean and let
            // `reconcile` re-adopt whatever audio is actually on disk.
            catalog = DownloadCatalog()
            return catalog
        }

        catalog = decoded
        return catalog
    }

    func markPending(_ entry: DownloadCatalog.Entry) -> DownloadCatalog {
        _ = load()
        catalog.pending[entry.song.id] = entry
        save()
        return catalog
    }

    /// Promotes a pending entry once its file is in place.
    func complete(songID: String, byteCount: Int64) -> DownloadCatalog {
        _ = load()
        guard var entry = catalog.pending.removeValue(forKey: songID) else { return catalog }
        entry.byteCount = byteCount
        entry.addedAt = .now
        catalog.entries[songID] = entry
        save()
        return catalog
    }

    func cancelPending(songID: String) -> DownloadCatalog {
        _ = load()
        catalog.pending.removeValue(forKey: songID)
        save()
        return catalog
    }

    func remove(songIDs: [String]) -> DownloadCatalog {
        _ = load()
        for id in songIDs {
            if let entry = catalog.entries.removeValue(forKey: id) {
                try? FileManager.default.removeItem(at: entry.url)
            }
            catalog.pending.removeValue(forKey: id)
            try? FileManager.default.removeItem(at: Paths.lyricsFile(songID: id))
        }
        save()
        return catalog
    }

    func removeAll() -> DownloadCatalog {
        _ = load()
        catalog = DownloadCatalog()
        save()

        // The directory is the truth for storage, so clear it wholesale rather than
        // per entry -- that also sweeps up anything the catalog had lost track of.
        for directory in [Paths.media, Paths.incoming, Paths.lyrics] {
            let contents = (try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: nil
            )) ?? []
            for file in contents where file.hasDirectoryPath == false {
                try? FileManager.default.removeItem(at: file)
            }
        }
        return catalog
    }

    /// Reality check against the filesystem, run once at launch.
    ///
    /// Two directions, both of which happen for real:
    /// - An entry whose file is gone (restored device, manual clear) is dropped.
    /// - A pending entry whose file *is* on disk is promoted. That is the crash
    ///   window between the delegate's move and the catalog write; without this the
    ///   download would appear to have failed while occupying storage.
    func reconcile() -> DownloadCatalog {
        _ = load()
        var changed = false

        for (id, entry) in catalog.entries {
            if !FileManager.default.fileExists(atPath: entry.url.path) {
                catalog.entries.removeValue(forKey: id)
                changed = true
            }
        }

        for (id, entry) in catalog.pending {
            let attributes = try? FileManager.default.attributesOfItem(atPath: entry.url.path)
            guard let size = (attributes?[.size] as? NSNumber)?.int64Value, size > 0 else {
                continue
            }

            var promoted = entry
            promoted.byteCount = size
            promoted.addedAt = .now
            catalog.pending.removeValue(forKey: id)
            catalog.entries[id] = promoted
            changed = true
        }

        // Staged files never survive a relaunch: the URLSession temp file they were
        // being written from is gone, so they can only be dead weight.
        let staged = (try? FileManager.default.contentsOfDirectory(
            at: Paths.incoming, includingPropertiesForKeys: nil
        )) ?? []
        for file in staged {
            try? FileManager.default.removeItem(at: file)
        }

        if changed { save() }
        return catalog
    }

    /// Atomic, so a kill mid-write cannot leave a half-written catalog that fails to
    /// decode and takes the whole library's index with it.
    private func save() {
        guard let data = try? JSONEncoder().encode(catalog) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
