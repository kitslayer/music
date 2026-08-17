import Foundation
import Observation

/// Keeps the play queue the same on this phone and on desktop Feishin.
///
/// Subsonic stores one queue per *user*, not per client, so both apps already point at
/// the same slot — this just uses it. Start an album on the phone, open the desktop
/// client, and it is on the same track at the same second.
///
/// Two rules keep it from fighting itself:
///
/// - **Never adopt our own save.** The server reports `changedBy`, so a queue this app
///   wrote is ignored on the way back. Without that, every launch would restore the
///   queue we had just uploaded, overwriting anything changed since.
/// - **Never adopt silently over a newer local queue.** The locally persisted snapshot
///   has its own timestamp; the server only wins if it is genuinely more recent.
@MainActor
@Observable
final class QueueSync {
    /// Set when a remote queue is available and newer, so the UI can offer it rather
    /// than yanking playback out from under someone.
    private(set) var available: Remote?
    private(set) var lastPushedAt: Date?

    struct Remote: Equatable {
        var songs: [Song]
        var currentID: String?
        var positionSeconds: Double
        var changedBy: String
        var changedAt: Date
    }

    private weak var client: SubsonicClient?
    private var pushTask: Task<Void, Never>?
    /// Signature of what was last uploaded, so an unchanged queue is not re-sent on
    /// every pause.
    private var lastPushedSignature: String?

    func configure(client: SubsonicClient) {
        self.client = client
    }

    func reset() {
        pushTask?.cancel()
        pushTask = nil
        available = nil
        lastPushedSignature = nil
        lastPushedAt = nil
    }

    // MARK: - Uploading

    /// Debounced. Called on the transitions that matter — track change, pause,
    /// backgrounding — not on a timer, because the position only needs to be roughly
    /// right for another device to pick up.
    func push(queue: PlaybackQueue, elapsed: Double) {
        guard client != nil, !queue.isEmpty else { return }

        let ids = queue.order.compactMap { index in
            queue.tracks.indices.contains(index) ? queue.tracks[index].id : nil
        }
        guard !ids.isEmpty else { return }

        let currentID = queue.current?.id
        let signature = "\(currentID ?? "")|\(Int(elapsed))|\(ids.count)|\(ids.first ?? "")"
        guard signature != lastPushedSignature else { return }

        pushTask?.cancel()
        pushTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled, let self, let client else { return }

            do {
                try await client.saveQueue(
                    songIDs: ids,
                    currentID: currentID,
                    positionMilliseconds: Int(elapsed * 1000)
                )
                lastPushedSignature = signature
                lastPushedAt = .now
            } catch {
                // A failed sync is not worth surfacing: the local queue is already
                // persisted on disk, and the next transition retries.
            }
        }
    }

    /// Forced, for backgrounding — where there is no next transition to wait for.
    func pushNow(queue: PlaybackQueue, elapsed: Double) {
        pushTask?.cancel()
        lastPushedSignature = nil
        push(queue: queue, elapsed: elapsed)
    }

    // MARK: - Downloading

    /// Looks for a queue saved by another client. Does not apply it — that is the
    /// caller's decision, because adopting one means interrupting whatever is playing.
    func check(localSavedAt: Date?) async {
        guard let client else { return }
        guard let saved = try? await client.savedQueue(), !saved.songs.isEmpty else {
            available = nil
            return
        }

        let changedBy = saved.changedBy ?? ""
        guard changedBy != SubsonicAuth.clientName else {
            available = nil
            return
        }

        guard let changedAt = saved.changedAt else {
            available = nil
            return
        }

        // Only if genuinely newer than what this phone already has.
        if let localSavedAt, changedAt <= localSavedAt {
            available = nil
            return
        }

        available = Remote(
            songs: saved.songs,
            currentID: saved.current,
            positionSeconds: Double(saved.position ?? 0) / 1000,
            changedBy: changedBy.isEmpty ? "another device" : changedBy,
            changedAt: changedAt
        )
    }

    func dismiss() {
        available = nil
    }
}
