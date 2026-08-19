import Foundation

/// Working out what will fit on the phone before a trip, and how much of it is already
/// there.
///
/// The arithmetic is the feature. Five days of listening in the library's own FLAC is
/// roughly 54 GB, which fits on nothing; at 256 kbps it is about 1.7 GB, which fits on
/// anything. Getting that comparison in front of someone *before* they tap download is
/// the whole point, so it is pure, Foundation-only and tested.
enum TripPlanner {
    /// An album or a playlist. Whole groups are preferred over loose tracks: three songs
    /// off a record is a worse thing to find on a plane than the record.
    struct Group: Sendable, Identifiable {
        let id: String
        let name: String
        var subtitle: String?
        let songs: [Song]

        var seconds: Int { songs.reduce(0) { $0 + ($1.duration ?? 0) } }
    }

    struct Plan: Sendable {
        var groups: [Group] = []
        /// Only the tracks that still have to be fetched.
        var toDownload: [Song] = []
        var seconds: Int = 0
        var bytesToDownload: Int64 = 0
        /// What the already-downloaded part of the plan is worth. Usually the most
        /// reassuring number on the screen.
        var bytesAlready: Int64 = 0
        var alreadyCount: Int = 0
        /// Set when the plan stopped short because the phone would have run out of room.
        var isSpaceLimited = false

        var songCount: Int { groups.reduce(0) { $0 + $1.songs.count } }
    }

    /// Never plan into the last of the free space: iOS starts behaving badly well before
    /// zero, and a music app is not the thing that should push it there.
    static let reserveBytes: Int64 = 2_000_000_000

    /// Fill `targetSeconds` of listening from `groups`, cheapest-first.
    ///
    /// "Cheapest" means most already downloaded: a group that is entirely on the phone
    /// costs nothing and counts in full, so most trips are half-planned before a byte
    /// moves. Ties go to the order the caller supplied, which is its own ranking.
    static func plan(
        groups: [Group],
        downloaded: Set<String>,
        targetSeconds: Int,
        quality: DownloadQuality,
        freeBytes: Int64,
        reserveBytes: Int64 = TripPlanner.reserveBytes
    ) -> Plan {
        let budget = max(0, freeBytes - reserveBytes)

        let ordered = groups.enumerated().sorted { left, right in
            let a = downloadedFraction(left.element, downloaded: downloaded)
            let b = downloadedFraction(right.element, downloaded: downloaded)
            if a != b { return a > b }
            return left.offset < right.offset
        }

        var plan = Plan()
        var seenIdentities: Set<String> = []
        var seenIDs: Set<String> = []

        for (_, group) in ordered {
            guard plan.seconds < targetSeconds else { break }

            // The two music folders overlap heavily, so the same record can appear twice
            // under different ids. Downloading both is the worst possible use of the space
            // this screen is trying to save.
            let songs = group.songs.filter { song in
                !seenIDs.contains(song.id) && !seenIdentities.contains(MixEngine.identity(song))
            }
            guard !songs.isEmpty else { continue }

            let missing = songs.filter { !downloaded.contains($0.id) }
            let cost = missing.reduce(Int64(0)) { $0 + quality.estimatedBytes(for: $1) }

            if plan.bytesToDownload + cost > budget {
                // Skip rather than stop: a smaller group later may still fit, and the
                // caller's list is ordered by preference, not by size.
                plan.isSpaceLimited = true
                continue
            }

            for song in songs {
                seenIDs.insert(song.id)
                seenIdentities.insert(MixEngine.identity(song))
            }

            plan.groups.append(Group(
                id: group.id, name: group.name, subtitle: group.subtitle, songs: songs
            ))
            plan.toDownload += missing
            plan.bytesToDownload += cost
            plan.seconds += songs.reduce(0) { $0 + ($1.duration ?? 0) }

            let present = songs.filter { downloaded.contains($0.id) }
            plan.alreadyCount += present.count
            plan.bytesAlready += present.reduce(Int64(0)) { $0 + Int64($1.size ?? 0) }
        }

        return plan
    }

    private static func downloadedFraction(_ group: Group, downloaded: Set<String>) -> Double {
        guard !group.songs.isEmpty else { return 0 }
        let present = group.songs.filter { downloaded.contains($0.id) }.count
        return Double(present) / Double(group.songs.count)
    }

    /// Hours of listening a trip needs. Days times hours per day, which is how people
    /// actually describe a trip.
    static func targetSeconds(days: Int, hoursPerDay: Int) -> Int {
        max(0, days) * max(0, hoursPerDay) * 3_600
    }
}
