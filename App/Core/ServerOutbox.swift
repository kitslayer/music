import Foundation

/// Plays that have not reached the server yet.
///
/// The point of this app is that listening offline still counts — the same history,
/// the same play counts, the same "most played" shelf as the desktop client. So a
/// scrobble that fails is not dropped; it waits on disk.
///
/// **One file per mutation**, not one array in one file. An array means
/// read-modify-write, and two concurrent flushes or a kill mid-write can lose a whole
/// batch of plays. A file per mutation makes each one independently durable and
/// independently deletable, and the directory listing *is* the queue.
actor ServerOutbox {
    struct Pending: Codable, Sendable {
        let songID: String
        /// When it was listened to, which is what gets submitted -- not now.
        let listenedAt: Date
        var attempts: Int = 0
    }

    private let directory: URL
    /// Given up on. 30 days of retries is generous, and a permanently-rejected id
    /// (a track deleted from the server) must not be retried forever.
    private let maximumAttempts = 40

    init(directory: URL = Paths.outbox) {
        self.directory = directory
    }

    var count: Int {
        files().count
    }

    func enqueue(songID: String, listenedAt: Date) {
        let pending = Pending(songID: songID, listenedAt: listenedAt)
        // The filename carries the timestamp so a plain name sort is chronological --
        // zero-padded, because otherwise the sort breaks the day the epoch gains a
        // digit -- plus a uuid, so two plays of one track in one second cannot collide.
        let stamp = String(format: "%012d", Int(listenedAt.timeIntervalSince1970))
        let name = "\(stamp)-\(UUID().uuidString).json"
        guard let data = try? JSONEncoder().encode(pending) else { return }
        try? data.write(to: directory.appendingPathComponent(name), options: .atomic)
    }

    /// Submits everything, oldest first, and stops at the first network failure --
    /// there is no point hammering a server that is not reachable, and order is worth
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
                try await client.scrobble(
                    id: pending.songID,
                    submission: true,
                    at: pending.listenedAt
                )
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
