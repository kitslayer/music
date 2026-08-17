import AVFoundation
import Foundation

/// Owns the `AVAudioSession` and the notifications that go with it.
///
/// The rules encoded here are the ones that produce "playback resumes but is
/// silent" and "the app stole audio at launch" bugs when they are missed.
@MainActor
final class AudioSessionCoordinator {
    /// Called when the system wants playback paused or resumed.
    var onPause: (() -> Void)?
    var onResume: (() -> Void)?

    private var isActivated = false
    private var wasPlayingBeforeInterruption = false
    private var observers: [NSObjectProtocol] = []

    func configure() {
        let session = AVAudioSession.sharedInstance()
        // .longFormAudio is what marks this as a music app for routing and AirPlay 2.
        // Deliberately no .mixWithOthers: it is incompatible with that policy.
        try? session.setCategory(.playback, mode: .default, policy: .longFormAudio)
        observeNotifications()
    }

    /// Activated lazily on the first play. Activating a `.playback` session at
    /// launch silently stops whatever the user was already listening to.
    func activate() {
        guard !isActivated else { return }
        try? AVAudioSession.sharedInstance().setActive(true)
        isActivated = true
    }

    /// Holding an active session with nothing playing invites termination.
    func deactivate() {
        guard isActivated else { return }
        try? AVAudioSession.sharedInstance().setActive(
            false,
            options: .notifyOthersOnDeactivation
        )
        isActivated = false
    }

    private func observeNotifications() {
        let center = NotificationCenter.default

        observers.append(center.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            MainActor.assumeIsolated {
                self?.handleInterruption(notification)
            }
        })

        observers.append(center.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            MainActor.assumeIsolated {
                self?.handleRouteChange(notification)
            }
        })
    }

    private func handleInterruption(_ notification: Notification) {
        guard let info = notification.userInfo,
              let rawType = info[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: rawType)
        else { return }

        switch type {
        case .began:
            // An `.appWasSuspended` interruption is never followed by `.ended`, so
            // there is no resume to wait for.
            if let rawReason = info[AVAudioSessionInterruptionReasonKey] as? UInt,
               rawReason == AVAudioSession.InterruptionReason.appWasSuspended.rawValue {
                wasPlayingBeforeInterruption = false
            }
            onPause?()

        case .ended:
            let options = (info[AVAudioSessionInterruptionOptionKey] as? UInt)
                .map(AVAudioSession.InterruptionOptions.init(rawValue:)) ?? []

            guard options.contains(.shouldResume), wasPlayingBeforeInterruption else { return }

            // Reactivating *before* resuming is essential; skipping it is the
            // classic cause of playback that resumes but produces no sound.
            isActivated = false
            activate()
            onResume?()

        @unknown default:
            break
        }
    }

    private func handleRouteChange(_ notification: Notification) {
        guard let raw = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: raw)
        else { return }

        // Headphones pulled out or an AirPod removed. Never auto-resume when a new
        // device appears -- that starts music in someone's pocket.
        if reason == .oldDeviceUnavailable {
            onPause?()
        }
    }

    func noteIsPlaying(_ isPlaying: Bool) {
        wasPlayingBeforeInterruption = isPlaying
    }
}
