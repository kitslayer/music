import Foundation
import MediaPlayer
import UIKit

/// Lock screen and Control Centre.
@MainActor
final class NowPlayingCenter {
    var onPlay: (() -> Void)?
    var onPause: (() -> Void)?
    var onToggle: (() -> Void)?
    var onNext: (() -> Void)?
    var onPrevious: (() -> Void)?
    var onSeek: ((Double) -> Void)?

    private var info: [String: Any] = [:]

    init() {
        registerCommands()
    }

    /// Targets are added exactly once. Re-registering per track change is the
    /// standard bug and produces double-skips.
    private func registerCommands() {
        let center = MPRemoteCommandCenter.shared()

        center.playCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated { self?.onPlay?() }
            return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated { self?.onPause?() }
            return .success
        }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated { self?.onToggle?() }
            return .success
        }
        center.nextTrackCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated { self?.onNext?() }
            return .success
        }
        center.previousTrackCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated { self?.onPrevious?() }
            return .success
        }

        // Must be enabled or the lock-screen scrubber never appears at all.
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else {
                return .commandFailed
            }
            MainActor.assumeIsolated { self?.onSeek?(event.positionTime) }
            return .success
        }

        for command in [center.playCommand, center.pauseCommand, center.togglePlayPauseCommand,
                        center.nextTrackCommand, center.previousTrackCommand,
                        center.changePlaybackPositionCommand] {
            command.isEnabled = true
        }

        // Leaving these enabled makes iOS show 15-second skip buttons instead of
        // previous/next, which is wrong for a music app.
        center.skipForwardCommand.isEnabled = false
        center.skipBackwardCommand.isEnabled = false
    }

    /// `elapsedPlaybackTime` is published only on state transitions. The system
    /// extrapolates from (elapsed, rate, timestamp), so pushing it from a timer makes
    /// the lock-screen slider stutter and fight the user's drag.
    func update(
        song: Song,
        elapsed: Double,
        duration: Double,
        isPlaying: Bool,
        queueIndex: Int,
        queueCount: Int
    ) {
        // Mutate a local copy and assign once: in-place read-modify-write of
        // nowPlayingInfo is slow and not thread-safe in practice.
        var next = info

        next[MPMediaItemPropertyTitle] = song.title
        next[MPMediaItemPropertyArtist] = song.artist ?? ""
        next[MPMediaItemPropertyAlbumTitle] = song.album ?? ""
        next[MPMediaItemPropertyPlaybackDuration] = duration
        next[MPNowPlayingInfoPropertyElapsedPlaybackTime] = elapsed
        next[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0
        next[MPNowPlayingInfoPropertyDefaultPlaybackRate] = 1.0
        next[MPNowPlayingInfoPropertyIsLiveStream] = false
        next[MPNowPlayingInfoPropertyPlaybackQueueIndex] = queueIndex
        next[MPNowPlayingInfoPropertyPlaybackQueueCount] = queueCount
        next[MPNowPlayingInfoPropertyMediaType] = MPNowPlayingInfoMediaType.audio.rawValue

        // Artwork belongs to the previous track until the new one arrives.
        if currentArtworkSongID != song.id {
            next[MPMediaItemPropertyArtwork] = nil
            currentArtworkSongID = nil
        }

        info = next
        MPNowPlayingInfoCenter.default().nowPlayingInfo = next
    }

    private var currentArtworkSongID: String?

    /// Set separately so lock-screen text is never gated on a network fetch.
    ///
    /// The request handler is called on an arbitrary thread and must return
    /// synchronously, so the image has to be in hand before the object is built.
    func setArtwork(_ image: UIImage, songID: String? = nil) {
        currentArtworkSongID = songID
        let artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
        info[MPMediaItemPropertyArtwork] = artwork
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    func clear() {
        info = [:]
        currentArtworkSongID = nil
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }
}
