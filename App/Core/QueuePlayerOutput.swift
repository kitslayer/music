import AVFoundation
import Foundation

/// The default output: `AVQueuePlayer` with a three-item window.
///
/// This is the one that handles the hard cases correctly for free — streaming with
/// byte-range seeking, network stalls, interruptions, route changes — so it stays the
/// default and the enhanced engine is opt-in.
///
/// Preloading the next item is what makes an album boundary gapless. The window is
/// three rather than the whole queue because inserting a 292-track playlist would be a
/// connection stampede.
@MainActor
final class QueuePlayerOutput: AudioOutput {
    private(set) var elapsed: Double = 0
    private(set) var duration: Double = 0
    private(set) var isBuffering = false

    var volume: Float {
        get { player.volume }
        set { player.volume = newValue }
    }

    var onAdvanced: ((String?) -> Void)?
    var onTick: ((Double, Bool) -> Void)?
    var locate: ((Song) -> MediaLocation?)?

    private let player = AVQueuePlayer()
    /// `AVPlayerItem` is single-use, so this maps the live items back to songs.
    private var itemToSongID: [ObjectIdentifier: String] = [:]
    private var expectedItem: AVPlayerItem?
    private var spectrum: AudioSampleBuffer?
    /// Never removed: the observer is owned by the player, which is owned by this
    /// object, so they are deallocated together. A `deinit` that touched it could not
    /// be expressed under strict concurrency anyway -- `Any?` is not `Sendable`.
    private var timeObserver: Any?

    init() {
        player.actionAtItemEnd = .advance
        addTimeObserver()
    }

    /// Attaches or removes the sample tap.
    ///
    /// Turning it on also reaches the item already playing, so opening the visualiser
    /// mid-track shows something immediately instead of waiting for the next one. Track
    /// loading is async, hence the `Task`; `audioMix` can be set on a playing item.
    /// Attaches the tap, and **never detaches it**.
    ///
    /// Mutating `audioMix` on a *playing* item makes AVFoundation rebuild its audio
    /// processing graph, which is audible as a break in playback. Tearing the tap down
    /// whenever the visualiser left the screen therefore made every switch between
    /// artwork, lyrics and the visualiser click.
    ///
    /// The tap is a passthrough that does one `memcpy`, so leaving it in place costs
    /// effectively nothing and the analyser simply stops reading. Attaching once, on the
    /// first visualiser open, is the only graph change that happens.
    func setSpectrumSink(_ buffer: AudioSampleBuffer?) {
        guard let buffer, spectrum == nil else { return }
        spectrum = buffer

        // Future items pick it up in `makeItem`, before they are playing. Only the item
        // already playing has to be changed underneath, and only this once.
        if let item = player.currentItem {
            Task { await attachTap(to: item, feeding: buffer) }
        }
    }

    private func attachTap(to item: AVPlayerItem, feeding buffer: AudioSampleBuffer) async {
        guard item.audioMix == nil,
              let track = try? await item.asset.loadTracks(withMediaType: .audio).first,
              let mix = AudioTap.makeMix(for: track, feeding: buffer)
        else { return }
        item.audioMix = mix
    }

    // MARK: - Loading

    func load(window: [Song], startAt: Double) {
        player.removeAllItems()
        itemToSongID.removeAll()

        guard let current = window.first else {
            duration = 0
            elapsed = 0
            return
        }

        for song in window {
            guard let item = makeItem(for: song), player.canInsert(item, after: nil) else {
                continue
            }
            player.insert(item, after: nil)
        }

        expectedItem = player.currentItem
        duration = Double(current.duration ?? 0)
        elapsed = startAt

        if startAt > 0 { seek(to: startAt) }
    }

    func updateUpcoming(_ songs: [Song]) {
        let alreadyQueued = player.items().dropFirst().compactMap {
            itemToSongID[ObjectIdentifier($0)]
        }
        guard Array(alreadyQueued) != songs.map(\.id) else { return }

        // Drop everything after the current item and re-add: an `AVPlayerItem` cannot
        // be reordered or reused, so rebuilding the tail is the only option.
        for item in player.items().dropFirst() {
            itemToSongID[ObjectIdentifier(item)] = nil
            player.remove(item)
        }
        for song in songs {
            if let item = makeItem(for: song), player.canInsert(item, after: nil) {
                player.insert(item, after: nil)
            }
        }
    }

    // MARK: - Transport

    func play() {
        player.play()
    }

    func pause() {
        player.pause()
    }

    func seek(to seconds: Double) {
        let target = CMTime(seconds: max(0, seconds), preferredTimescale: 600)
        // Hops rather than asserting: unlike the periodic time observer, which is
        // explicitly given the main queue, a seek completion carries no such promise.
        player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            Task { @MainActor in
                self?.elapsed = seconds
            }
        }
    }

    func stop() {
        player.pause()
        player.removeAllItems()
        itemToSongID.removeAll()
        expectedItem = nil
        elapsed = 0
        duration = 0
    }

    // MARK: - Items

    private func makeItem(for song: Song) -> AVPlayerItem? {
        guard let location = locate?(song) else { return nil }

        var options: [String: Any] = [:]
        if !location.isLocal, let mime = location.mimeType {
            options[AVURLAssetOverrideMIMETypeKey] = mime
        }

        let asset = AVURLAsset(url: location.url, options: options)
        let item = AVPlayerItem(asset: asset)
        itemToSongID[ObjectIdentifier(item)] = song.id

        // Set here rather than when the item becomes current: an item in the preload
        // window is not playing yet, so giving it a mix now costs nothing, where doing it
        // at the track boundary would click.
        if let spectrum {
            Task { await attachTap(to: item, feeding: spectrum) }
        }

        return item
    }

    // MARK: - Time

    private func addTimeObserver() {
        // 4 Hz: enough for a smooth scrubber, and cheap. Item advancement is detected
        // here by identity rather than by KVO, which would arrive on an internal queue
        // and need an unsafe hop under strict concurrency.
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
            let songID = player.currentItem.flatMap { itemToSongID[ObjectIdentifier($0)] }
            onAdvanced?(songID)
            return
        }

        elapsed = time.seconds.isFinite ? time.seconds : 0
        isBuffering = player.timeControlStatus == .waitingToPlayAtSpecifiedRate

        if duration == 0, let itemDuration = player.currentItem?.duration.seconds,
           itemDuration.isFinite, itemDuration > 0 {
            duration = itemDuration
        }

        onTick?(elapsed, player.timeControlStatus == .playing)
    }
}
