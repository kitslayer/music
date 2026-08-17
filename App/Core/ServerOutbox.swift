import Foundation

/// Everything owed to the server that has not reached it yet.
///
/// The point of this app is that listening offline still counts — the same history, the
/// same play counts, the same stars as the desktop client. So a mutation that fails is
/// not dropped; it waits on disk.
///
/// **One file per mutation**, not one array in one file. An array means
/// read-modify-write, and two concurrent flushes or a kill mid-write can lose a whole
/// batch. A file per mutation makes each independently durable and independently
/// deletable, and the directory listing *is* the queue.
actor ServerOutbox {
    /// What kind of thing is owed. Scrobbles carry the original listen time; the others
/// are idempotent, so replaying one late is harmless.
    enum Kind: String, Codable, Sendable {
        case scrobble
        case star
        case unstar
        case rating
    }

    struct Pending: Codable, Sendable {
        /// Defaulted so files written by the scrobble-only version still decode.
        var kind: Kind = .scrobble
        let songID: String
        /// When it happened, which is what gets submitted for a scrobble — not now.
        let listenedAt: Date
        /// `star`/`unstar` target kind: song, album or artist.
        var target: String?
        /// `rating` only.
        var rating: Int?
        var attempts: Int = 0
    }

    private let directory: URL
    /// Given up on. 30 days of retries is generous, and a permanently-rejected id — a
    /// track deleted from the server — must not be retried forever.
    private let maximumAttempts = 40

    init(directory: URL = Paths.outbox) {
        self.directory = directory
    }

    var count: Int {
        files().count
    }

    /// Counts by kind, for the diagnostics row.
    func summary() -> [Kind: Int] {
        var result: [Kind: Int] = [:]
        for file in files() {
            guard let data = try? Data(contentsOf: file),
                  let pending = try? JSONDecoder().decode(Pending.self, from: data)
            else { continue }
            result[pending.kind, default: 0] += 1
        }
        return result
    }

    func enqueue(songID: String, listenedAt: Date) {
        write(Pending(kind: .scrobble, songID: songID, listenedAt: listenedAt))
    }

    func enqueueStar(id: String, target: String, starred: Bool) {
        write(Pending(
            kind: starred ? .star : .unstar,
            songID: id,
            listenedAt: .now,
            target: target
        ))
    }

    func enqueueRating(id: String, rating: Int) {
        write(Pending(kind: .rating, songID: id, listenedAt: .now, rating: rating))
    }

    private func write(_ pending: Pending) {
        // The filename carries the timestamp so a plain name sort is chronological --
        // zero-padded, because otherwise the sort breaks the day the epoch gains a
        // digit -- plus a uuid, so two writes in one second cannot collide.
        let stamp = String(format: "%012d", Int(pending.listenedAt.timeIntervalSince1970))
        let name = "\(stamp)-\(UUID().uuidString).json"
        guard let data = try? JSONEncoder().encode(pending) else { return }
        try? data.write(to: directory.appendingPathComponent(name), options: .atomic)
    }

    /// Submits everything, oldest first, and stops at the first network failure — there
    /// is no point hammering a server that is not reachable, and order is worth
    /// preserving in the history.
    func flush(using client: SubsonicClient) async -> Int {
        var sent = 0

        for file in files() {
            guard let data = try? Data(contentsOf: file),
                  var pending = try? JSONDecoder().decode(Pending.self, from: data)
            else {
                // Undecodable: delete it rather than block the queue behind it.
                try? FileManager.default.removeItem(at: file)
                continue
            }

            do {
                try await submit(pending, using: client)
                try? FileManager.default.removeItem(at: file)
                sent += 1
            } catch {
                pending.attempts += 1
                if pending.attempts >= maximumAttempts {
                    try? FileManager.default.removeItem(at: file)
                } else if let updated = try? JSONEncoder().encode(pending) {
                    try? updated.write(to: file, options: .atomic)
                }
                break
            }
        }

        return sent
    }

    private func submit(_ pending: Pending, using client: SubsonicClient) async throws {
        switch pending.kind {
        case .scrobble:
            try await client.scrobble(
                id: pending.songID,
                submission: true,
                at: pending.listenedAt
            )
        case .star:
            try await client.star(id: pending.songID, kind: starKind(pending.target))
        case .unstar:
            try await client.unstar(id: pending.songID, kind: starKind(pending.target))
        case .rating:
            try await client.setRating(id: pending.songID, rating: pending.rating ?? 0)
        }
    }

    private func starKind(_ raw: String?) -> SubsonicClient.StarKind {
        switch raw {
        case "album": return .album
        case "artist": return .artist
        default: return .song
        }
    }

    private func files() -> [URL] {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )) ?? []
        return contents
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
}
