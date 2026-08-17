import AVFoundation
import Foundation
import MediaPlayer
import Observation
import UIKit

/// Everything the UI talks to for playback.
///
/// `@MainActor` rather than an actor: `AVQueuePlayer`, `MPNowPlayingInfoCenter` and
/// `UIImage` are all main-thread-affine and non-`Sendable`, so actor isolation would
/// mean an unsafe opt-out plus a hop on every remote command and time tick.
@MainActor
@Observable
final class PlaybackController {
    // MARK: - Observable state

    private(set) var queue = PlaybackQueue()
    private(set) var isPlaying = false
    private(set) var isBuffering = false
    /// Seconds. Read by the in-app scrubber at 4 Hz.
    private(set) var elapsed: Double = 0
    private(set) var duration: Double = 0

    var currentSong: Song? { queue.current }
    var hasQueue: Bool { !queue.isEmpty }

    // MARK: - Dependencies

    private let player = AVQueuePlayer()
    private let session = AudioSessionCoordinator()
    private let nowPlaying = NowPlayingCenter()
    private let store = PlaybackQueueStore(url: Paths.queue)
    private let tracker = PlayTracker()
    private weak var appState: AppState?

    /// AVPlayerItem is single-use, so this maps the live items back to songs.
    private var itemToSongID: [ObjectIdentifier: String] = [:]
    private var expectedItem: AVPlayerItem?
    private var timeObserver: Any?
    private var saveTask: Task<Void, Never>?

    /// Current + 2 upcoming. Preloading the next item is what makes the boundary
    /// gapless; inserting a 292-track playlist would be a connection stampede.
    private let windowSize = 3

    init() {
        player.actionAtItemEnd = .advance
        session.configure()

        session.onPause = { [weak self] in self?.pause() }
        session.onResume = { [weak self] in self?.play() }

        nowPlaying.onPlay = { [weak self] in self?.play() }
        nowPlaying.onPause = { [weak self] in self?.pause() }
        nowPlaying.onToggle = { [weak self] in self?.togglePlayPause() }
        nowPlaying.onNext = { [weak self] in self?.next() }
        nowPlaying.onPrevious = { [weak self] in self?.previous() }
        nowPlaying.onSeek = { [weak self] time in self?.seek(to: time) }

        // Fire-and-forget both ways. A lost "now playing" is cosmetic, and a lost
        // play count is what the durable outbox exists to prevent later; neither is
        // worth blocking or failing playback over.
        tracker.onNowPlaying = { [weak self] event in
            self?.report(event, submission: false)
        }
        tracker.onPlayCounted = { [weak self] event in
            self?.report(event, submission: true)
        }

        addTimeObserver()
    }

    func attach(appState: AppState) {
        self.appState = appState
    }

    // MARK: - Starting playback

    func play(songs: [Song], startingAt index: Int, source: String, shuffled: Bool = false) {
        guard !songs.isEmpty else { return }

        queue = .make(
            tracks: songs,
            startingAt: index,
            shuffled: shuffled,
            source: source,
            repeatMode: queue.repeatMode
        )

        rebuildPlayerItems(startPlaying: true, seekTo: 0)
    }

    func playNext(_ songs: [Song]) {
        guard !songs.isEmpty else { return }
        if queue.isEmpty {
            play(songs: songs, startingAt: 0, source: "Queue")
            return
        }
        queue.insertNext(songs)
        refillWindow()
        persist()
    }

    func append(_ songs: [Song]) {
        guard !songs.isEmpty else { return }
        if queue.isEmpty {
            play(songs: songs, startingAt: 0, source: "Queue")
            return
        }
        queue.append(songs)
        refillWindow()
        persist()
    }

    // MARK: - Transport

    func play() {
        guard hasQueue else { return }
        session.activate()
        player.play()
        isPlaying = true
        session.noteIsPlaying(true)
        publishNowPlaying(force: true)
        persist()
    }

    func pause() {
        player.pause()
        isPlaying = false
        tracker.interrupted(at: elapsed)
        session.noteIsPlaying(false)
        publishNowPlaying(force: true)
        persist()
    }

    func togglePlayPause() {
        isPlaying ? pause() : play()
    }

    /// Used by the sleep timer. Restores the volume afterwards, so the next manual
    /// play is not silent -- the single most likely bug in a fade implementation.
    func fadeOutAndPause(over duration: Double = 6) {
        guard isPlaying else { return }

        Task { [weak self] in
            let steps = 30
            for step in 1...steps {
                guard let self, isPlaying else { return }
                player.volume = Float(1 - Double(step) / Double(steps))
                try? await Task.sleep(for: .seconds(duration / Double(steps)))
            }
            guard let self else { return }
            pause()
            player.volume = 1
        }
    }

    func next() {
        guard queue.advance() else {
            pause()
            return
        }
        rebuildPlayerItems(startPlaying: isPlaying, seekTo: 0)
    }

    /// Rewinds first, the way every native player does, and only then goes back.
    func previous() {
        if elapsed > 3 {
            seek(to: 0)
            return
        }
        guard queue.rewind() else {
            seek(to: 0)
            return
        }
        rebuildPlayerItems(startPlaying: isPlaying, seekTo: 0)
    }

    func seek(to seconds: Double) {
        let target = CMTime(seconds: max(0, seconds), preferredTimescale: 600)
        player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.elapsed = seconds
                self.tracker.interrupted(at: seconds)
                self.publishNowPlaying(force: true)
            }
        }
    }

    func jump(toOrderIndex index: Int) {
        queue.jump(toOrderIndex: index)
        rebuildPlayerItems(startPlaying: true, seekTo: 0)
    }

    func removeFromQueue(orderIndex index: Int) {
        let wasCurrent = index == queue.position
        queue.remove(atOrderIndex: index)

        if wasCurrent {
            rebuildPlayerItems(startPlaying: isPlaying, seekTo: 0)
        } else {
            refillWindow()
            persist()
        }
    }

    func moveInQueue(from source: Int, to destination: Int) {
        queue.move(fromOrderIndex: source, toOrderIndex: destination)
        refillWindow()
        persist()
    }

    func toggleShuffle() {
        if queue.isShuffled {
            queue.unshuffle()
        } else {
            queue.shuffle(keepingCurrent: true)
        }
        refillWindow()
        persist()
    }

    func cycleRepeat() {
        queue.repeatMode = queue.repeatMode.next
        persist()
    }

    // MARK: - Scrobbling

    private func report(_ event: PlayTracker.Event, submission: Bool) {
        guard let appState else { return }

        guard submission else {
            // "Now playing" is ephemeral -- it expires on the server in minutes, so
            // queueing a stale one would be worse than losing it.
            Task { try? await appState.client.scrobble(id: event.songID, submission: false) }
            return
        }

        Task {
            do {
                try await appState.client.scrobble(
                    id: event.songID, submission: true, at: event.listenedAt
                )
            } catch {
                // Offline, or the server is down. The play is owed either way, so it
                // goes to disk with the time it actually happened.
                await appState.outbox.enqueue(
                    songID: event.songID, listenedAt: event.listenedAt
                )
            }
        }
    }

    // MARK: - Player items

    private func rebuildPlayerItems(startPlaying: Bool, seekTo seconds: Double) {
        player.removeAllItems()
        itemToSongID.removeAll()

        guard let current = queue.current else {
            isPlaying = false
            return
        }

        var items: [AVPlayerItem] = []
        if let item = makeItem(for: current) { items.append(item) }
        for song in queue.upcoming(windowSize - 1) {
            if let item = makeItem(for: song) { items.append(item) }
        }

        for item in items {
            if player.canInsert(item, after: nil) {
                player.insert(item, after: nil)
            }
        }

        expectedItem = player.currentItem
        duration = Double(current.duration ?? 0)
        elapsed = seconds
        tracker.trackChanged(to: current, duration: duration)
        tracker.interrupted(at: seconds)

        if seconds > 0 { seek(to: seconds) }

        if startPlaying {
            play()
        } else {
            publishNowPlaying(force: true)
        }
    }

    /// Keeps the window topped up without disturbing what is already playing.
    private func refillWindow() {
        let wanted = queue.upcoming(windowSize - 1)
        let alreadyQueued = player.items().dropFirst().compactMap {
            itemToSongID[ObjectIdentifier($0)]
        }

        guard Array(alreadyQueued) != wanted.map(\.id) else { return }

        // Drop everything after the current item and re-add: AVPlayerItem cannot be
        // reordered or reused, so rebuilding the tail is the only option.
        for item in player.items().dropFirst() {
            itemToSongID[ObjectIdentifier(item)] = nil
            player.remove(item)
        }
        for song in wanted {
            if let item = makeItem(for: song), player.canInsert(item, after: nil) {
                player.insert(item, after: nil)
            }
        }
    }

    private func makeItem(for song: Song) -> AVPlayerItem? {
        guard let appState else { return nil }

        var options: [String: Any] = [:]

        // A downloaded file wins over the network unconditionally: it is the original
        // bytes, it is instant, and it works with the server switched off. This is the
        // whole reason downloads exist, so it is checked before anything else.
        let url: URL
        if let local = appState.downloads.localURL(for: song.id) {
            url = local
        } else {
            guard let signer = appState.signer,
                  // Always `raw`: a transcoded response is chunked with no
                  // Content-Length and no byte ranges, which breaks seeking.
                  let streamURL = signer.url("stream.view", ["format": "raw", "id": song.id])
            else { return nil }
            url = streamURL

            // `stream.view` has no path extension, so AVFoundation has nothing to
            // sniff and FLAC fails to pick a decoder. Override the type explicitly.
            // A local file has its extension, so this is only needed when streaming.
            if let mime = song.contentType ?? Self.mimeType(for: song.suffix) {
                options[AVURLAssetOverrideMIMETypeKey] = mime
            }
        }

        let asset = AVURLAsset(url: url, options: options)
        let item = AVPlayerItem(asset: asset)
        itemToSongID[ObjectIdentifier(item)] = song.id
        return item
    }

    private static func mimeType(for suffix: String?) -> String? {
        switch suffix?.lowercased() {
        case "flac": return "audio/flac"
        case "mp3": return "audio/mpeg"
        case "m4a", "aac", "mp4": return "audio/mp4"
        case "wav": return "audio/wav"
        case "aiff", "aif": return "audio/aiff"
        default: return nil
        }
    }

    // MARK: - Time

    private func addTimeObserver() {
        // 4 Hz: enough for a smooth scrubber, and cheap. Item advancement is
        // detected here by identity rather than by KVO, which would be delivered on
        // an internal queue and need an unsafe hop under strict concurrency.
        let interval = CMTime(value: 1, timescale: 4)
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: interval,
            queue: .main
        ) { [weak self] time in
            MainActor.assumeIsolated {
                self?.tick(time)
            }
        }
    }

    private func tick(_ time: CMTime) {
        if player.currentItem !== expectedItem {
            expectedItem = player.currentItem
            handleAdvancedItem()
            return
        }

        elapsed = time.seconds.isFinite ? time.seconds : 0
        isBuffering = player.timeControlStatus == .waitingToPlayAtSpecifiedRate

        if duration == 0, let itemDuration = player.currentItem?.duration.seconds,
           itemDuration.isFinite, itemDuration > 0 {
            duration = itemDuration
            tracker.trackChanged(to: queue.current, duration: duration)
        }

        // Only while the audio is genuinely moving: a stalled buffer still ticks.
        if isPlaying, player.timeControlStatus == .playing {
            tracker.advanced(to: elapsed)
        } else {
            tracker.interrupted(at: elapsed)
        }
    }

    /// The player moved on by itself, so follow it in the logical queue.
    private func handleAdvancedItem() {
        if queue.repeatMode == .one {
            seek(to: 0)
            play()
            return
        }

        guard let currentItem = player.currentItem,
              let songID = itemToSongID[ObjectIdentifier(currentItem)],
              let orderIndex = queue.order.firstIndex(where: { queue.tracks[$0].id == songID })
        else {
            // Ran off the end of the window.
            if queue.advance() {
                rebuildPlayerItems(startPlaying: true, seekTo: 0)
            } else {
                pause()
            }
            return
        }

        appState?.sleepTimer.trackDidFinish()

        queue.position = orderIndex
        duration = Double(queue.current?.duration ?? 0)
        elapsed = 0
        tracker.trackChanged(to: queue.current, duration: duration)
        refillWindow()
        publishNowPlaying(force: true)
        persist()
    }

    // MARK: - Now Playing

    private func publishNowPlaying(force: Bool) {
        guard let song = queue.current else {
            nowPlaying.clear()
            return
        }

        nowPlaying.update(
            song: song,
            elapsed: elapsed,
            duration: duration > 0 ? duration : Double(song.duration ?? 0),
            isPlaying: isPlaying,
            queueIndex: queue.position,
            queueCount: queue.order.count
        )

        if let artwork = appState?.artwork {
            let id = song.coverArt
            Task { @MainActor in
                if let image = await artwork.image(for: id, size: .full) {
                    nowPlaying.setArtwork(image)
                }
            }
        }
    }

    // MARK: - Persistence

    /// Debounced, plus forced on the transitions that matter. Backgrounding does not
    /// kill the app while audio plays; the real risks are termination while paused
    /// and crashes.
    private func persist() {
        saveTask?.cancel()
        let snapshot = QueueSnapshot(queue: queue, positionSeconds: elapsed, savedAt: .now)
        saveTask = Task { [store] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            await store.save(snapshot)
        }
    }

    func persistNow() {
        let snapshot = QueueSnapshot(queue: queue, positionSeconds: elapsed, savedAt: .now)
        Task { [store] in await store.save(snapshot) }
    }

    /// Restores the previous queue **paused**. Auto-playing on launch is hostile.
    func restore() async {
        guard let snapshot = await store.load(), !snapshot.queue.isEmpty else { return }
        queue = snapshot.queue
        rebuildPlayerItems(startPlaying: false, seekTo: snapshot.positionSeconds)
    }
}
