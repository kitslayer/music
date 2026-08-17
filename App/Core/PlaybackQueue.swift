import Foundation

enum RepeatMode: String, Codable, Sendable, CaseIterable {
    case off, all, one

    var symbol: String {
        switch self {
        case .off, .all: return "repeat"
        case .one: return "repeat.1"
        }
    }

    var next: RepeatMode {
        switch self {
        case .off: return .all
        case .all: return .one
        case .one: return .off
        }
    }
}

/// The logical queue, independent of AVFoundation.
///
/// Shuffle is stored as a **permutation** rather than a shuffled copy of the array.
/// That makes un-shuffling exact, keeps "Up Next" stable across toggles, and keeps
/// the snapshot small.
struct PlaybackQueue: Codable, Sendable {
    /// Always the original, unshuffled order.
    var tracks: [Song] = []
    /// A permutation of indices into `tracks`; the identity when unshuffled.
    var order: [Int] = []
    /// Index into `order`, not into `tracks`.
    var position: Int = 0
    var repeatMode: RepeatMode = .off
    var isShuffled: Bool = false
    /// "Kid A", "Freedom" -- shown in the player as the source of the queue.
    var sourceDescription: String = ""

    var isEmpty: Bool { tracks.isEmpty }

    var current: Song? {
        guard order.indices.contains(position) else { return nil }
        let index = order[position]
        return tracks.indices.contains(index) ? tracks[index] : nil
    }

    func upcoming(_ count: Int) -> [Song] {
        guard !order.isEmpty else { return [] }
        let start = position + 1
        guard start < order.count else { return [] }
        return order[start..<min(start + count, order.count)].map { tracks[$0] }
    }

    /// Everything after the current track, for the queue view.
    var upNext: [Song] {
        upcoming(max(order.count - position - 1, 0))
    }

    static func make(
        tracks: [Song],
        startingAt index: Int,
        shuffled: Bool,
        source: String,
        repeatMode: RepeatMode = .off
    ) -> PlaybackQueue {
        var queue = PlaybackQueue(
            tracks: tracks,
            order: Array(tracks.indices),
            position: 0,
            repeatMode: repeatMode,
            isShuffled: false,
            sourceDescription: source
        )
        queue.position = queue.order.firstIndex(of: index) ?? 0
        if shuffled { queue.shuffle(keepingCurrent: true) }
        return queue
    }

    mutating func shuffle(keepingCurrent: Bool) {
        guard !order.isEmpty else { return }

        let currentTrackIndex = order.indices.contains(position) ? order[position] : nil
        var shuffledOrder = Array(tracks.indices).shuffled()

        if keepingCurrent, let currentTrackIndex,
           let where_ = shuffledOrder.firstIndex(of: currentTrackIndex) {
            shuffledOrder.swapAt(0, where_)
            position = 0
        }

        order = shuffledOrder
        isShuffled = true
    }

    mutating func unshuffle() {
        guard isShuffled else { return }
        let currentTrackIndex = order.indices.contains(position) ? order[position] : 0
        order = Array(tracks.indices)
        position = currentTrackIndex
        isShuffled = false
    }

    /// Advances honouring the repeat mode. Returns false when the queue is done.
    mutating func advance() -> Bool {
        guard !order.isEmpty else { return false }

        switch repeatMode {
        case .one:
            return true // same track; the player seeks to zero
        case .off:
            guard position + 1 < order.count else { return false }
            position += 1
            return true
        case .all:
            position = (position + 1) % order.count
            return true
        }
    }

    mutating func rewind() -> Bool {
        guard !order.isEmpty else { return false }
        if position > 0 {
            position -= 1
            return true
        }
        if repeatMode == .all {
            position = order.count - 1
            return true
        }
        return false
    }

    mutating func jump(toOrderIndex index: Int) {
        guard order.indices.contains(index) else { return }
        position = index
    }

    mutating func insertNext(_ songs: [Song]) {
        guard !songs.isEmpty else { return }
        let insertAt = tracks.count
        tracks.append(contentsOf: songs)
        let newIndices = Array(insertAt..<tracks.count)
        order.insert(contentsOf: newIndices, at: min(position + 1, order.count))
    }

    mutating func append(_ songs: [Song]) {
        guard !songs.isEmpty else { return }
        let insertAt = tracks.count
        tracks.append(contentsOf: songs)
        order.append(contentsOf: Array(insertAt..<tracks.count))
    }

    mutating func remove(atOrderIndex index: Int) {
        guard order.indices.contains(index) else { return }
        order.remove(at: index)
        if index < position { position -= 1 }
        position = min(position, max(order.count - 1, 0))
    }

    mutating func move(fromOrderIndex source: Int, toOrderIndex destination: Int) {
        guard order.indices.contains(source) else { return }
        let value = order.remove(at: source)
        order.insert(value, at: min(destination, order.count))
    }
}

/// What is written to disk: the queue plus where we were in the current track.
struct QueueSnapshot: Codable, Sendable {
    var queue: PlaybackQueue
    var positionSeconds: Double
    var savedAt: Date
}

/// Persists the queue so a relaunch resumes where you were.
actor PlaybackQueueStore {
    private let url: URL

    init(url: URL) {
        self.url = url
    }

    func load() -> QueueSnapshot? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(QueueSnapshot.self, from: data)
    }

    func save(_ snapshot: QueueSnapshot) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        // Atomic: a crash mid-write must not leave a half-written queue.
        try? data.write(to: url, options: .atomic)
    }

    func clear() {
        try? FileManager.default.removeItem(at: url)
    }
}
