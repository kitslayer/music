import Foundation
import Observation

/// Three mixes, rebuilt once a day.
///
/// The reason this can exist at all is that the app keeps its own play log: the server
/// knows *how many* times a track was played but not *when*, so "what you have been into
/// lately" is not a question Subsonic can answer. `MixEngine` does the choosing; this
/// fetches the candidates and remembers the result.
///
/// Deliberately once a day, not on every launch. A mix that changes while you are looking
/// at it is not a mix, and thirteen requests per launch to rebuild something identical is
/// rude to a server that also has Plex on it.
@MainActor
@Observable
final class DailyMixes {
    struct Mix: Codable, Sendable, Identifiable {
        let id: String
        var title: String
        var subtitle: String
        var songs: [Song]

        /// Up to four covers, for the tiled card. Distinct albums, so a mix that happens
        /// to open with three tracks off one record still looks like a mix.
        var covers: [String] {
            var seen: [String] = []
            for art in songs.compactMap(\.coverArt) where !seen.contains(art) {
                seen.append(art)
                if seen.count == 4 { break }
            }
            return seen
        }
    }

    /// Below this a "mix" is a short playlist. Twelve rather than fifteen because the
    /// original figure was silently dropping mixes that were perfectly usable: eight
    /// favourite artists at three tracks each is 24 candidates *before* de-duplication and
    /// the excluded week, and this library's twin copies eat a lot of that.
    static let minimumTracks = 12

    private(set) var mixes: [Mix] = []
    private(set) var isBuilding = false

    private var builtDay: Date?
    private var builtScope: String?
    private var buildTask: Task<Void, Never>?
    /// Attempts today, so a library that genuinely cannot fill more than one mix does not
    /// get rebuilt on every visit to Home.
    private var attemptsToday = 0
    private var attemptDay: Date?

    private struct Stored: Codable, Sendable {
        var day: Date
        var scope: String
        var mixes: [Mix]
    }

    func mix(id: String) -> Mix? { mixes.first { $0.id == id } }

    /// Throws away today's answer so the next `load` rebuilds. Used by the Diagnostics
    /// screen, since "why is this shelf empty" is otherwise unanswerable from the phone.
    func forgetToday() {
        buildTask?.cancel()
        buildTask = nil
        builtDay = nil
        builtScope = nil
        attemptsToday = 0
        mixes = []
    }

    /// Restores today's mixes from disk, or builds them.
    ///
    /// **Not** `async`, and the work runs in a task this object owns. It used to be awaited
    /// straight from Home's `.task`, which SwiftUI cancels the moment that view goes away —
    /// so opening a mix, or switching tabs, killed the build part-way through. The first
    /// stage had already finished, so what got cached for the day was Heavy Rotation and
    /// nothing else. An unstructured `Task` does not inherit that cancellation.
    ///
    /// Yesterday's are shown while today's are being built, and kept if the build fails —
    /// offline, stale mixes are worth far more than an empty shelf, and every track in them
    /// is playable if it was downloaded.
    func load(appState: AppState, scope: LibraryScope) {
        let today = Calendar.current.startOfDay(for: .now)
        if builtDay == today, builtScope == scope.cacheKey, !mixes.isEmpty { return }
        guard buildTask == nil else { return }

        buildTask = Task { [weak self] in
            await self?.restoreThenBuild(appState: appState, scope: scope, day: today)
            self?.buildTask = nil
        }
    }

    /// Waits for whatever build is in flight. For the Diagnostics button, which wants to
    /// show the outcome rather than start it and walk away.
    func loadAndWait(appState: AppState, scope: LibraryScope) async {
        load(appState: appState, scope: scope)
        await buildTask?.value
    }

    private func restoreThenBuild(appState: AppState, scope: LibraryScope, day today: Date) async {
        let scopeKey = scope.cacheKey
        let key = "daily-mixes-\(scopeKey)"

        if mixes.isEmpty, let stored: Stored = await appState.cache.load(Stored.self, for: key) {
            mixes = stored.mixes
            builtDay = stored.day
            builtScope = stored.scope
            // A stored day with a full set is done. A short set is worth one more go, in
            // case it was a build that got cut off.
            if stored.day == today, stored.scope == scopeKey, stored.mixes.count >= 3 { return }
        }

        if attemptDay != today {
            attemptDay = today
            attemptsToday = 0
        }
        guard attemptsToday < 3, !isBuilding else { return }
        attemptsToday += 1

        isBuilding = true
        let built = await build(appState: appState, scope: scope, day: today)
        isBuilding = false

        guard built.count >= mixes.count || builtDay != today else {
            // A retry that did worse than what is already on screen changes nothing.
            await Diagnostics.shared.record("mixes", "rebuild produced fewer — keeping what was there")
            return
        }

        guard !built.isEmpty else {
            // Logged because the failure is invisible otherwise: an empty shelf simply
            // does not render, which looks identical to the feature not existing.
            await Diagnostics.shared.record("mixes", "built nothing — see the stage lines above")
            return
        }
        await Diagnostics.shared.record(
            "mixes", "built " + built.map { "\($0.id):\($0.songs.count)" }.joined(separator: " ")
        )
        mixes = built
        builtDay = today
        builtScope = scopeKey
        await appState.cache.store(Stored(day: today, scope: scopeKey, mixes: built), for: key)
    }

    // MARK: - Building

    private func build(appState: AppState, scope: LibraryScope, day: Date) async -> [Mix] {
        let samples = await samples(appState: appState)
        guard !samples.isEmpty else {
            await Diagnostics.shared.record(
                "mixes", "no history and no server play counts — nothing to build from"
            )
            return []
        }
        await Diagnostics.shared.record(
            "mixes",
            "\(samples.count) samples (\(appState.history.plays.count) local plays)"
        )

        let artists = MixEngine.ranked(MixEngine.artistScores(samples), limit: 8)
        let recent = MixEngine.songIDs(samples, playedWithin: 7)

        // One `used` set across all three, so the same track cannot turn up in two mixes
        // on the same day.
        var used: Set<String> = []
        var identities: Set<String> = []
        var built: [Mix] = []

        let (heavy, candidates) = await heavyRotation(
            appState: appState, artists: artists, recent: recent, day: day,
            used: &used, identities: &identities
        )
        if let heavy { built.append(heavy) }

        // Two genres, not one: with one, the shelf was Heavy Rotation and a single
        // near-neighbour of it. The second genre is usually a different mood entirely,
        // which is the point of a shelf rather than a button.
        let genres = await topGenres(
            appState: appState, samples: samples, candidates: candidates, scope: scope, limit: 2
        )
        for (index, genre) in genres.enumerated() {
            if let mix = await genreMix(
                appState: appState, genre: genre, index: index, scope: scope, day: day,
                used: &used, identities: &identities
            ) {
                built.append(mix)
            }
        }

        if let mix = await deepCuts(
            appState: appState, artists: artists, scope: scope, day: day,
            used: &used, identities: &identities
        ) {
            built.append(mix)
        }

        if let mix = await newToYou(
            appState: appState, samples: samples, scope: scope, day: day,
            used: &used, identities: &identities
        ) {
            built.append(mix)
        }

        if let mix = await freshAdditions(
            appState: appState, scope: scope, day: day,
            used: &used, identities: &identities
        ) {
            built.append(mix)
        }

        return built
    }

    /// Tracks by favourite artists that have never once been played.
    ///
    /// Different from New to You, which reaches for anything unplayed: this stays with
    /// artists already loved and finds the album tracks behind the songs. `getTopSongs`
    /// cannot answer it — by definition it returns the *played* ones — so this searches by
    /// artist name and filters on the play count.
    private func deepCuts(
        appState: AppState,
        artists: [String],
        scope: LibraryScope,
        day: Date,
        used: inout Set<String>,
        identities: inout Set<String>
    ) async -> Mix? {
        var pool: [Song] = []
        for artist in artists.prefix(4) {
            let found = try? await appState.client.search(
                query: artist, artistCount: 0, albumCount: 0, songCount: 60, scope: scope
            )
            pool += (found?.songs ?? []).filter {
                ($0.playCount ?? 0) == 0
                    && $0.artist?.localizedCaseInsensitiveContains(artist) == true
            }
        }
        guard !pool.isEmpty else { return nil }

        var generator = MixEngine.DayRandom(day: day, salt: 4)
        let chosen = MixEngine.choose(
            from: pool, limit: 25, perArtist: 4,
            excluding: used, usedIdentities: identities, using: &generator
        )
        await Diagnostics.shared.record(
            "mixes", "deep cuts: \(pool.count) candidates, \(chosen.count) chosen"
        )
        guard chosen.count >= Self.minimumTracks else { return nil }
        record(chosen, into: &used, &identities)

        return Mix(
            id: "deep",
            title: "Deep Cuts",
            subtitle: "Unplayed, by artists you know",
            songs: chosen
        )
    }

    /// Newly added music that has not been touched yet.
    ///
    /// Whole albums are the unit here because new arrivals are usually albums — often ones
    /// Hermes just fetched — and hearing one in order is the point.
    private func freshAdditions(
        appState: AppState,
        scope: LibraryScope,
        day: Date,
        used: inout Set<String>,
        identities: inout Set<String>
    ) async -> Mix? {
        let albums = (try? await appState.client.albums(type: .newest, size: 10, scope: scope)) ?? []
        var pool: [Song] = []

        for album in albums.prefix(6) {
            guard let detail = try? await appState.client.albumDetail(id: album.id) else { continue }
            pool += detail.songs.filter { ($0.playCount ?? 0) == 0 }
        }
        guard !pool.isEmpty else { return nil }

        var generator = MixEngine.DayRandom(day: day, salt: 5)
        let chosen = MixEngine.choose(
            from: pool, limit: 25, perArtist: 6,
            excluding: used, usedIdentities: identities, using: &generator
        )
        await Diagnostics.shared.record(
            "mixes", "fresh: \(albums.count) new albums, \(pool.count) unplayed, \(chosen.count) chosen"
        )
        guard chosen.count >= Self.minimumTracks else { return nil }
        record(chosen, into: &used, &identities)

        return Mix(
            id: "fresh",
            title: "Fresh Additions",
            subtitle: "Recently added, not yet played",
            songs: chosen
        )
    }

    /// The play log, or the server's counts when the log is too thin to mean anything.
    ///
    /// Cold start is where the Plex import earns its keep: 1,322 tracks already carry a
    /// play count, so day one is personal instead of random. Server rows have no genre —
    /// only the app's own log does — which is why the genre mix has its own fallback.
    private func samples(appState: AppState) async -> [MixEngine.Sample] {
        var samples = appState.history.plays.map {
            MixEngine.Sample(songID: $0.songID, artist: $0.artist, genre: $0.genre, at: $0.at)
        }

        guard samples.count < 40 else { return samples }

        let counted = (try? await appState.native.mostPlayed(limit: 200)) ?? []
        samples += counted.compactMap { song in
            guard let artist = song.artist, let count = song.playCount, count > 0 else { return nil }
            return MixEngine.Sample(
                songID: song.id,
                artist: artist,
                genre: nil,
                // No play *events* to place, so the last play stands in for all of them.
                at: song.playDate ?? .now,
                weight: Double(count)
            )
        }
        return samples
    }

    /// Favourite artists, minus this week's listening. Returns the candidates too, since
    /// they carry the genre tags the next mix needs and were expensive to fetch.
    private func heavyRotation(
        appState: AppState,
        artists: [String],
        recent: Set<String>,
        day: Date,
        used: inout Set<String>,
        identities: inout Set<String>
    ) async -> (Mix?, [Song]) {
        guard !artists.isEmpty else { return (nil, []) }

        var candidates: [Song] = []
        for artist in artists {
            var songs = (try? await appState.client.topSongs(artist: artist, count: 8)) ?? []
            // `getTopSongs` only really answers for artists with play history — Nirvana
            // came back with a single track — so a thin answer is topped up by search.
            if songs.count < 3 {
                let extra = try? await appState.client.search(query: artist, songCount: 12)
                songs += (extra?.songs ?? []).filter { $0.artist == artist }
            }
            candidates += songs
        }

        var generator = MixEngine.DayRandom(day: day, salt: 1)
        // This week's listening goes to the back rather than being thrown out. Filtering
        // it out was the bug: the top artists are precisely the ones just played, so on an
        // active week the filter could take the pool below the minimum and the mix
        // vanished entirely — worse than showing a track heard on Tuesday.
        let ordered = candidates.filter { !recent.contains($0.id) }
            + candidates.filter { recent.contains($0.id) }
        let chosen = MixEngine.choose(
            from: ordered,
            limit: 25,
            perArtist: 3,
            excluding: used,
            usedIdentities: identities,
            using: &generator
        )

        await Diagnostics.shared.record(
            "mixes",
            "heavy: \(artists.count) artists, \(candidates.count) candidates, \(chosen.count) chosen"
        )
        guard chosen.count >= Self.minimumTracks else { return (nil, candidates) }
        record(chosen, into: &used, &identities)

        return (Mix(
            id: "heavy",
            title: "Heavy Rotation",
            subtitle: artists.prefix(3).joined(separator: ", "),
            songs: chosen
        ), candidates)
    }

    /// The genres someone actually listens to, not the biggest ones in the library.
    private func topGenres(
        appState: AppState,
        samples: [MixEngine.Sample],
        candidates: [Song],
        scope: LibraryScope,
        limit: Int
    ) async -> [String] {
        let scored = MixEngine.ranked(MixEngine.genreScores(samples), limit: limit)
        if !scored.isEmpty { return scored }

        // Cold start: the play log has no genres yet, but the tracks by favourite artists
        // do, so the most common genre among those is still a personal answer and costs
        // nothing extra.
        var counts: [String: Int] = [:]
        for genre in candidates.compactMap(\.genre) where !genre.isEmpty {
            counts[genre, default: 0] += 1
        }
        let fromCandidates = counts
            .sorted { ($0.value, $1.key) > ($1.value, $0.key) }
            .prefix(limit)
            .map(\.key)
        if !fromCandidates.isEmpty { return fromCandidates }

        // Nothing at all to go on: the library's own biggest genres.
        let genres = (try? await appState.client.genres(scope: scope)) ?? []
        return genres
            .sorted { ($0.songCount ?? 0) > ($1.songCount ?? 0) }
            .prefix(limit)
            .map(\.value)
    }

    private func genreMix(
        appState: AppState,
        genre: String,
        index: Int,
        scope: LibraryScope,
        day: Date,
        used: inout Set<String>,
        identities: inout Set<String>
    ) async -> Mix? {
        let pool = (try? await appState.client.songsByGenre(genre, count: 200, scope: scope)) ?? []
        guard !pool.isEmpty else {
            await Diagnostics.shared.record("mixes", "genre: “\(genre)” returned nothing")
            return nil
        }

        var generator = MixEngine.DayRandom(day: day, salt: UInt64(2 + index * 100))
        let chosen = MixEngine.choose(
            from: pool,
            limit: 25,
            perArtist: 2,
            excluding: used,
            usedIdentities: identities,
            using: &generator
        )
        await Diagnostics.shared.record(
            "mixes", "genre “\(genre)”: \(pool.count) candidates, \(chosen.count) chosen"
        )
        guard chosen.count >= Self.minimumTracks else { return nil }
        record(chosen, into: &used, &identities)

        // Named for the genre, because "Shoegaze Mix" says something and "Mix 2" does not.
        return Mix(
            id: "genre-\(index)",
            title: "\(genre) Mix",
            subtitle: "From your \(genre.lowercased()) corner",
            songs: chosen
        )
    }

    /// The only feature in the app that deliberately goes looking in the ~24,500 tracks
    /// that have never been played once.
    private func newToYou(
        appState: AppState,
        samples: [MixEngine.Sample],
        scope: LibraryScope,
        day: Date,
        used: inout Set<String>,
        identities: inout Set<String>
    ) async -> Mix? {
        var pool: [Song] = []

        for seed in seeds(from: samples) {
            let similar = (try? await appState.client.similarSongs(toSongID: seed, count: 50)) ?? []
            pool += similar
        }
        pool = pool.filter { ($0.playCount ?? 0) == 0 }

        // `getSimilarSongs2` gave 19 rows for a seed here, eleven of them unplayed, so
        // three seeds do not fill a mix on their own. Random songs do, and with 95% of the
        // library never played the filter barely costs anything.
        if pool.count < 25 {
            let random = (try? await appState.client.randomSongs(size: 200, scope: scope)) ?? []
            pool += random.filter { ($0.playCount ?? 0) == 0 }
        }
        guard !pool.isEmpty else {
            await Diagnostics.shared.record("mixes", "new: no never-played candidates came back")
            return nil
        }

        var generator = MixEngine.DayRandom(day: day, salt: 3)
        let chosen = MixEngine.choose(
            from: pool,
            limit: 25,
            perArtist: 2,
            excluding: used,
            usedIdentities: identities,
            using: &generator
        )
        await Diagnostics.shared.record(
            "mixes", "new: \(pool.count) unplayed candidates, \(chosen.count) chosen"
        )
        guard chosen.count >= Self.minimumTracks else { return nil }
        record(chosen, into: &used, &identities)

        return Mix(
            id: "new",
            title: "New to You",
            subtitle: "Never played, from your own library",
            songs: chosen
        )
    }

    /// Up to three of the most-played tracks, as seeds for similarity.
    ///
    /// Song ids, not artist ids: `getSimilarSongs2` returns nothing for an artist id on
    /// this server, which is already noted where the client method is defined.
    private func seeds(from samples: [MixEngine.Sample]) -> [String] {
        var weights: [String: Double] = [:]
        for sample in samples { weights[sample.songID, default: 0] += sample.weight }
        return MixEngine.ranked(weights, limit: 3)
    }

    private func record(_ songs: [Song], into used: inout Set<String>, _ identities: inout Set<String>) {
        for song in songs {
            used.insert(song.id)
            identities.insert(MixEngine.identity(song))
        }
    }
}
