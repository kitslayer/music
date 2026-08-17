import Foundation

/// Where a song's bytes are, and what they are.
struct MediaLocation: Sendable {
    let url: URL
    /// Needed only when streaming: `stream.view` has no path extension, so
    /// AVFoundation has nothing to sniff and FLAC fails to pick a decoder.
    let mimeType: String?
    /// A completed download. The engine output requires this for every track it
    /// touches, because `AVAudioFile` cannot read a URL.
    let isLocal: Bool
}

/// The thing that actually makes sound.
///
/// Two implementations, because no single one does everything asked of it:
///
/// - `QueuePlayerOutput` (`AVQueuePlayer`) streams, seeks by byte range, handles
///   interruptions correctly and is genuinely gapless — but cannot do EQ or crossfade,
///   because `AVPlayer` exposes no point to insert a processing node.
/// - `EngineOutput` (`AVAudioEngine`) can do both — but has no networking whatsoever,
///   so it only works when every track involved is a completed download.
///
/// `PlaybackController` owns the queue, the scrobbler, the lock screen and persistence
/// regardless of which of these is running, so switching output changes the sound path
/// and nothing else.
@MainActor
protocol AudioOutput: AnyObject {
    /// Seconds into the current track.
    var elapsed: Double { get }
    /// Seconds, or 0 when not yet known.
    var duration: Double { get }
    var isBuffering: Bool { get }
    /// For the sleep-timer fade. Separate from any crossfade ramping.
    var volume: Float { get set }

    /// Loads the current track plus the preload window, seeked to `startAt`.
    func load(window: [Song], startAt: Double)
    /// Replaces the upcoming part of the window without disturbing what is playing.
    func updateUpcoming(_ songs: [Song])

    func play()
    func pause()
    func seek(to seconds: Double)
    func stop()

    /// The output moved on by itself. The id is the song now playing, or nil when it
    /// ran off the end of the window and the controller has to decide what is next.
    var onAdvanced: ((String?) -> Void)? { get set }
    /// Roughly 4 Hz. `isMoving` is false while stalled, so the play tracker does not
    /// credit listening time to a buffering track.
    var onTick: ((_ elapsed: Double, _ isMoving: Bool) -> Void)? { get set }
    /// Where to find a song's bytes. Set by the controller; changes on sign-in.
    var locate: ((Song) -> MediaLocation?)? { get set }
}
