import AVFoundation
import Foundation
import MediaPlayer
import Observation
import UIKit

/// Everything the UI talks to for playback.
///
/// Owns the queue, the play tracker, the lock screen and persistence. It does **not**
/// own the sound: that is an `AudioOutput`, chosen per track window, so the EQ engine
/// and the streaming player are interchangeable without any of the above moving.
///
/// `@MainActor` rather than an actor: `AVQueuePlayer`, `AVAudioEngine`,
/// `MPNowPlayingInfoCenter` and `UIImage` are all main-thread-affine and
/// non-`Sendable`, so actor isolation would mean an unsafe opt-out plus a hop on every
/// remote command and time tick.
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

    /// The default sound path, and the only one that can stream.
    private let queueOutput = QueuePlayerOutput()
    /// Built once `AppState` exists, because it needs the EQ settings.
    private var engineOutput: EngineOutput?
    private var output: AudioOutput

    private let session = AudioSessionCoordinator()
    private let nowPlaying = NowPlayingCenter()
    private let store = PlaybackQueueStore(url: Paths.queue)
    private let tracker = PlayTracker()
    private weak var appState: AppState?

    private var saveTask: Task<Void, Never>?

    /// Current + 2 upcoming. Preloading the next item is what makes the boundary
    /// gapless; inserting a 292-track playlist would be a connection stampede.
    private let windowSize = 3

    init() {
        output = queueOutput
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

        wire(queueOutput)
    }

    func attach(appState: AppState) {
        self.appState = appState

        let engine = EngineOutput(settings: appState.audio)
        engineOutput = engine
        wire(engine)

        queueOutput.locate = { [weak self] song in self?.locate(song) }
        engine.locate = { [weak self] song in self?.locate(song) }
    }

    /// Both outputs are wired up front rather than on switch: a callback arriving from
    /// an output that has just been stopped is normal, and re-wiring on every switch
    /// would be one more place to get it wrong.
    private func wire(_ candidate: AudioOutput) {
        candidate.onAdvanced = { [weak self, weak candidate] songID in
            guard let self, let candidate, candidate === output else { return }
            handleAdvanced(to: songID)
        }
        candidate.onTick = { [weak self, weak candidate] elapsed, isMoving in
            guard let self, let candidate, candidate === output else { return }
            tick(elapsed: elapsed, isMoving: isMoving)
        }
    }

    /// Where a song's bytes are. A completed download wins over the network
    /// unconditionally: original bytes, instant, and works with the server off.
    private func locate(_ song: Song) -> MediaLocation? {
        guard let appState else { return nil }

        if let local = appState.downloads.localURL(for: song.id) {
            return MediaLocation(url: local, mimeType: nil, isLocal: true)
        }

        // Always `raw`: a transcoded response is chunked with no Content-Length and no
        // byte ranges, which breaks seeking.
        guard let signer = appState.signer,
              let url = signer.url("stream.view", ["format": "raw", "id": song.id])
        else { return nil }

        return MediaLocation(
            url: url,
            mimeType: song.contentType ?? Self.mimeType(for: song.suffix),
            isLocal: false
        )
    }

    /// Called when the EQ or crossfade settings change. Reloads at the current
    /// position only if the *choice* of output changed, so moving a slider does not
    /// interrupt the music.
    func audioSettingsChanged() {
        engineOutput?.applyEQ()

        guard hasQueue else { return }
        let window = currentWindow
        guard desiredOutput(for: window) !== output else { return }
        rebuildOutput(startPlaying: isPlaying, seekTo: elapsed)
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

        rebuildOutput(startPlaying: true, seekTo: 0)
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
        output.play()
        isPlaying = true
        session.noteIsPlaying(true)
        publishNowPlaying(force: true)
        persist()
    }

    func pause() {
        output.pause()
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
                output.volume = Float(1 - Double(step) / Double(steps))
                try? await Task.sleep(for: .seconds(duration / Double(steps)))
            }
            guard let self else { return }
            pause()
            output.volume = 1
        }
    }

    func next() {
        guard queue.advance() else {
            pause()
            return
        }
        rebuildOutput(startPlaying: isPlaying, seekTo: 0)
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
        rebuildOutput(startPlaying: isPlaying, seekTo: 0)
    }

    func seek(to seconds: Double) {
        output.seek(to: seconds)
        elapsed = seconds
        tracker.interrupted(at: seconds)
        publishNowPlaying(force: true)
    }

    func jump(toOrderIndex index: Int) {
        queue.jump(toOrderIndex: index)
        rebuildOutput(startPlaying: true, seekTo: 0)
    }

    func removeFromQueue(orderIndex index: Int) {
        let wasCurrent = index == queue.position
        queue.remove(atOrderIndex: index)

        if wasCurrent {
            rebuildOutput(startPlaying: isPlaying, seekTo: 0)
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

    // MARK: - Output selection

    /// Current track plus the preload window. Three items: preloading the next is what
    /// makes an album boundary gapless, and inserting a 292-track playlist would be a
    /// connection stampede.
    private var currentWindow: [Song] {
        guard let current = queue.current else { return [] }
        return [current] + queue.upcoming(windowSize - 1)
    }

    /// The engine output only when it is switched on *and* every track in the window
    /// is a completed download -- `AVAudioEngine` cannot read a URL, so a single
    /// streaming track in the window disqualifies it. Falling back silently is
    /// deliberate: the alternative is effects that half-work on half the library.
    private func desiredOutput(for window: [Song]) -> AudioOutput {
        guard let settings = appState?.audio, settings.isEnabled,
              let engine = engineOutput, engine.canServe(window)
        else { return queueOutput }
        return engine
    }

    private func rebuildOutput(startPlaying: Bool, seekTo seconds: Double) {
        let window = currentWindow

        guard let current = window.first else {
            output.stop()
            isPlaying = false
            return
        }

        let wanted = desiredOutput(for: window)
        if wanted !== output {
            output.stop()
            output = wanted
        }

        output.load(window: window, startAt: seconds)

        duration = Double(current.duration ?? 0)
        elapsed = seconds
        tracker.trackChanged(to: current, duration: duration)
        tracker.interrupted(at: seconds)

        if startPlaying {
            play()
        } else {
            publishNowPlaying(force: true)
        }
    }

    /// Keeps the preload window topped up without disturbing what is playing.
    private func refillWindow() {
        output.updateUpcoming(queue.upcoming(windowSize - 1))
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

    // MARK: - Time and transitions

    private func tick(elapsed newElapsed: Double, isMoving: Bool) {
        elapsed = newElapsed
        isBuffering = output.isBuffering

        // The queue's duration comes from the server and can be absent or wrong; the
        // output knows the real one once the file or stream is open.
        if duration == 0, output.duration > 0 {
            duration = output.duration
            tracker.trackChanged(to: queue.current, duration: duration)
        }

        // A stalled stream still ticks, so listening time is only credited while the
        // audio is genuinely moving.
        if isPlaying, isMoving {
            tracker.advanced(to: elapsed)
        } else {
            tracker.interrupted(at: elapsed)
        }
    }

    /// The output moved on by itself, so follow it in the logical queue.
    private func handleAdvanced(to songID: String?) {
        if queue.repeatMode == .one {
            seek(to: 0)
            play()
            return
        }

        guard let songID,
              let orderIndex = queue.order.firstIndex(where: { queue.tracks[$0].id == songID })
        else {
            // Ran off the end of the window, or the next track is one this output
            // cannot serve -- either way the queue decides and the output is rebuilt,
            // which is also where a fall back from the engine to streaming happens.
            if queue.advance() {
                rebuildOutput(startPlaying: true, seekTo: 0)
            } else {
                pause()
            }
            return
        }

        appState?.sleepTimer.trackDidFinish()

        queue.position = orderIndex
        duration = output.duration > 0 ? output.duration : Double(queue.current?.duration ?? 0)
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
        rebuildOutput(startPlaying: false, seekTo: snapshot.positionSeconds)
    }
}
