import Foundation

/// The arithmetic behind the daily mixes.
///
/// Foundation-only and compiled into the test package, because "why is this in my mix"
/// has to have an exact answer, and because a mix that reshuffles every time the screen
/// redraws feels broken. Everything here is deterministic: the same history and the same
/// day give the same mix, byte for byte.
enum MixEngine {
    /// One past play, reduced to what a mix needs to know about it.
    struct Sample: Sendable {
        let songID: String
        let artist: String
        var genre: String?
        let at: Date
        /// Usually one play. A cold start has no play *events* — only the server's
        /// per-track counts, which reach back through the Plex import — so those rows
        /// arrive as a single sample weighted by how often the track was played.
        var weight: Double = 1
    }

    /// Affinity halves every 30 days.
    ///
    /// So a play last week counts about 1.2× one from a month ago and 8× one from three
    /// months ago: the mixes follow what someone is into now rather than settling
    /// permanently on an all-time favourite.
    static let halfLifeDays = 30.0

    /// Plays per artist per day that count towards affinity. An album on repeat all
    /// afternoon is one enthusiasm, not fourteen; uncapped, a single evening owns the
    /// mixes for the next month.
    static let dailyCap = 5.0

    static func artistScores(
        _ samples: [Sample],
        now: Date = .now,
        calendar: Calendar = .current
    ) -> [String: Double] {
        scores(samples, now: now, calendar: calendar) { $0.artist }
    }

    static func genreScores(
        _ samples: [Sample],
        now: Date = .now,
        calendar: Calendar = .current
    ) -> [String: Double] {
        scores(samples, now: now, calendar: calendar) { $0.genre }
    }

    /// Half-life weighted totals, capped per key per day.
    private static func scores(
        _ samples: [Sample],
        now: Date,
        calendar: Calendar,
        by key: (Sample) -> String?
    ) -> [String: Double] {
        // Summed per day first, so the cap applies to a day's listening rather than to
        // the whole history.
        var daily: [String: [Date: Double]] = [:]
        for sample in samples {
            guard let name = key(sample), !name.isEmpty else { continue }
            let day = calendar.startOfDay(for: sample.at)
            daily[name, default: [:]][day, default: 0] += sample.weight
        }

        let today = calendar.startOfDay(for: now)
        var totals: [String: Double] = [:]
        for (name, days) in daily {
            var total = 0.0
            for (day, plays) in days {
                let elapsed = calendar.dateComponents([.day], from: day, to: today).day ?? 0
                // A play stamped in the future (clock skew, an import) counts as today
                // rather than being weighted up beyond 1.
                let decay = pow(0.5, Double(max(0, elapsed)) / halfLifeDays)
                total += min(plays, dailyCap) * decay
            }
            totals[name] = total
        }
        return totals
    }

    /// Highest score first. Ties broken by name, because dictionary order is not stable
    /// between runs and a mix that reorders itself for no reason looks like a bug.
    static func ranked(_ scores: [String: Double], limit: Int = .max) -> [String] {
        scores
            .sorted { ($0.value, $1.key) > ($1.value, $0.key) }
            .prefix(limit)
            .map(\.key)
    }

    /// Songs played in the last `days` days.
    ///
    /// Excluded from Heavy Rotation: a mix built from a favourite artist is worth having,
    /// a mix of the six tracks already played this morning is not.
    static func songIDs(_ samples: [Sample], playedWithin days: Int, now: Date = .now) -> Set<String> {
        let cutoff = now.addingTimeInterval(-Double(days) * 86_400)
        return Set(samples.filter { $0.at >= cutoff }.map(\.songID))
    }

    /// Deterministic randomness, keyed on the day.
    ///
    /// `shuffled()` and `randomElement()` differ every run, so without this the mixes
    /// would change on every redraw and could not be tested at all. Salted per mix so the
    /// three of them do not make identical choices out of overlapping candidates.
    struct DayRandom: RandomNumberGenerator {
        private var state: UInt64

        init(day: Date, salt: UInt64 = 0, calendar: Calendar = .current) {
            let start = calendar.startOfDay(for: day).timeIntervalSince1970
            state = UInt64(bitPattern: Int64(start)) ^ (salt &* 0x9E37_79B9_7F4A_7C15)
            // A zero state would emit zeros forever, which is a real possibility here
            // since the seed is arithmetic on a date rather than random bits.
            if state == 0 { state = 0x9E37_79B9_7F4A_7C15 }
        }

        /// splitmix64: three lines, well-distributed, and identical on every platform —
        /// which matters because a test asserts on the numbers it produces.
        mutating func next() -> UInt64 {
            state = state &+ 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    /// The identity two copies of the same recording share.
    ///
    /// This library has two overlapping folders: roughly 40% of tracks have a twin, and
    /// 4,957 title-and-artist groups are duplicated. Without collapsing them a mix shows
    /// the same song twice, which reads as carelessness rather than as a library problem.
    static func identity(_ song: Song) -> String {
        let title = (song.title).lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let artist = (song.artist ?? "").lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        return "\(artist)|\(title)"
    }

    /// Pick up to `limit` songs, at most `perArtist` by any one artist, skipping anything
    /// an earlier mix already used and any second copy of the same recording.
    ///
    /// Shuffled with the day's generator rather than taken in order, so Heavy Rotation is
    /// not the same three tracks off the top of each artist every single day.
    static func choose(
        from candidates: [Song],
        limit: Int,
        perArtist: Int,
        excluding used: Set<String>,
        usedIdentities: Set<String> = [],
        using generator: inout DayRandom
    ) -> [Song] {
        var perArtistCount: [String: Int] = [:]
        var identities = usedIdentities
        var chosen: [Song] = []

        for song in candidates.shuffled(using: &generator) {
            guard chosen.count < limit else { break }
            guard !used.contains(song.id) else { continue }

            let identity = identity(song)
            guard !identities.contains(identity) else { continue }

            let artist = song.artist ?? ""
            guard perArtistCount[artist, default: 0] < perArtist else { continue }

            perArtistCount[artist, default: 0] += 1
            identities.insert(identity)
            chosen.append(song)
        }
        return chosen
    }
}
