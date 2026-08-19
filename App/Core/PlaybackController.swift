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
    /// Set when playback started somewhere other than the beginning because a resume
    /// position was known. Drives the "Resumed from 42:10 · Start over" strip, which is
    /// the whole difference between a helpful resume and a baffling one.
    var resumeNotice: ResumeNotice?

    struct ResumeNotice: Equatable, Sendable {
        let songID: String
        let seconds: Double
    }
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
    /// Non-nil while a visualiser is on screen. Held here rather than in the output so
    /// it survives a switch between outputs mid-track.
    private var spectrumSink: AudioSampleBuffer?
    /// When the local queue was last written to disk, so `QueueSync` can tell whether a
    /// remote queue is genuinely newer.
    private(set) var lastSavedAt: Date?

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

        guard let signer = appState.signer else { return nil }

        // AVFoundation has no Vorbis or Opus decoder, so those containers must be
        // transcoded by the server or they simply fail with no explanation. Verified:
        // `format=mp3` returns `audio/mpeg`, but **chunked with no Content-Length**, so
        // seeking within those tracks is unreliable. Playing without reliable scrubbing
        // beats not playing, and it affects 11 files out of 25,784.
        if Self.needsTranscode(song.suffix) {
            guard let url = signer.url(
                "stream.view",
                ["format": "mp3", "id": song.id, "maxBitRate": "320"]
            ) else { return nil }
            return MediaLocation(url: url, mimeType: "audio/mpeg", isLocal: false)
        }

        // Otherwise always `raw`: a transcoded response is chunked with no
        // Content-Length and no byte ranges, which breaks seeking.
        guard let url = signer.url("stream.view", ["format": "raw", "id": song.id])
        else { return nil }

        return MediaLocation(
            url: url,
            mimeType: song.contentType ?? Self.mimeType(for: song.suffix),
            isLocal: false
        )
    }

    /// Replaces the queue with one from another device, paused at its position.
    func adopt(songs: [Song], currentID: String?, positionSeconds: Double, source: String) {
        guard !songs.isEmpty else { return }
        let index = currentID.flatMap { id in songs.firstIndex { $0.id == id } } ?? 0

        queue = .make(
            tracks: songs,
            startingAt: index,
            shuffled: false,
            source: source,
            repeatMode: queue.repeatMode
        )
        rebuildOutput(startPlaying: false, seekTo: positionSeconds)
        persistNow()
    }

    // MARK: - Visualiser

    /// There is deliberately no `stopSpectrum`. Detaching the tap means changing the
    /// audio graph while it is running, which is audible, so once attached it stays --
    /// the analyser stopping is what makes it free.
    func startSpectrum() {
        guard let appState else { return }
        spectrumSink = appState.spectrumBuffer
        output.setSpectrumSink(spectrumSink)
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

    /// `startAt` is seconds into the first track — for "play from this lyric", and for
    /// resuming a long track where it was left. Passed into the rebuild rather than
    /// seeking afterwards, which would race the output coming up.
    func play(
        songs: [Song],
        startingAt index: Int,
        source: String,
        shuffled: Bool = false,
        startAt seconds: Double = 0
    ) {
        guard !songs.isEmpty else { return }

        queue = .make(
            tracks: songs,
            startingAt: index,
            shuffled: shuffled,
            source: source,
            repeatMode: queue.repeatMode
        )

        // A saved position only applies when the caller did not ask for one, and only to
        // tracks long enough for it to matter -- `ResumeStore` decides both.
        var startSeconds = seconds
        if seconds == 0, let current = queue.current,
           let resume = appState?.resume.resumePoint(for: current) {
            startSeconds = resume
            resumeNotice = ResumeNotice(songID: current.id, seconds: resume)
        } else {
            resumeNotice = nil
        }

        rebuildOutput(startPlaying: true, seekTo: startSeconds)
    }

    /// Discards the resume position and starts the current track again.
    func startOver() {
        if let song = queue.current { appState?.resume.clear(songID: song.id) }
        resumeNotice = nil
        seek(to: 0)
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
        // Pausing is when someone walks away, which is exactly what a resume position is
        // for. Track changes and finishing are handled where they happen.
        appState?.resume.note(song: queue.current, elapsed: elapsed)
        session.noteIsPlaying(false)
        publishNowPlaying(force: true)
        persist()
    }

    /// The app came back to the foreground.
    ///
    /// Only ever resumes music that an interruption paused, and only when nothing else is
    /// using the speaker — the coordinator holds both conditions.
    func appBecameActive() {
        session.resumeIfInterruptionWentUnreported()
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

        if submission, let song = queue.current, song.id == event.songID {
            // Recorded here rather than in the tracker so the local history and the
            // server's counts are written from the same decision -- they can differ in
            // reach, but never in whether a play happened.
            appState.history.record(song, at: event.listenedAt)
        }

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
            output.setSpectrumSink(nil)
            output.stop()
            output = wanted
            // The visualiser must follow the switch, or opening it on a streamed track
            // and then reaching a downloaded one would silently go flat.
            output.setSpectrumSink(spectrumSink)
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

    /// Containers iOS cannot decode natively. Kept explicit rather than inverted from
    /// a supported list, so a container that merely lacks a MIME mapping is not
    /// needlessly transcoded.
    static func needsTranscode(_ suffix: String?) -> Bool {
        ["ogg", "oga", "opus", "wma", "ape", "wv"].contains(suffix?.lowercased() ?? "")
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
        //
        // Adopted whenever it becomes known, not only while ours is still zero. The old
        // guard meant a track with no server duration whose length the output could not
        // determine at first stayed at 0:00 for its whole play -- the player showed
        // "6:09 of 0:00" -- and it also meant a wrong server duration could never be
        // corrected.
        if output.duration > 0, abs(output.duration - duration) > 0.5 {
            duration = output.duration
            tracker.trackChanged(to: queue.current, duration: duration)
        } else if duration <= 0, let known = queue.current?.duration, known > 0 {
            // Last resort, and the one that actually matters: whatever went wrong when
            // this track started, the queue still knows how long it is. Checked every
            // tick, so a duration that failed to apply once corrects itself within a
            // quarter of a second instead of reading 0:00 for the whole track.
            duration = Double(known)
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
        // Played to the end: there is nothing to come back to.
        if let finished = queue.current { appState?.resume.clear(songID: finished.id) }
        resumeNotice = nil

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
            let songID = song.id
            Task { @MainActor in
                guard let image = await artwork.image(for: id, size: .full) else { return }
                // Two guards, both needed. The song id lets `update` tell whether the
                // artwork it already has belongs to the track being published -- passing
                // nil made it clear and re-fetch the artwork on every play/pause, which
                // is a visible blink on the lock screen. And a fetch that started for
                // the previous track must not land on this one.
                guard queue.current?.id == songID else { return }
                nowPlaying.setArtwork(image, songID: songID)
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
        lastSavedAt = snapshot.savedAt
        saveTask = Task { [store] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            await store.save(snapshot)
        }
        // Debounced inside QueueSync, so this is safe on every transition.
        appState?.queueSync.push(queue: queue, elapsed: elapsed)
    }

    func persistNow() {
        let snapshot = QueueSnapshot(queue: queue, positionSeconds: elapsed, savedAt: .now)
        lastSavedAt = snapshot.savedAt
        Task { [store] in await store.save(snapshot) }
        appState?.queueSync.pushNow(queue: queue, elapsed: elapsed)
    }

    /// Restores the previous queue **paused**. Auto-playing on launch is hostile.
    func restore() async {
        guard let snapshot = await store.load(), !snapshot.queue.isEmpty else { return }
        lastSavedAt = snapshot.savedAt
        queue = snapshot.queue
        rebuildOutput(startPlaying: false, seekTo: snapshot.positionSeconds)
    }
}
