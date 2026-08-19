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
    /// Mirrors the controller's play state, kept current by `noteIsPlaying`.
    private var isPlaying = false
    /// Latched when an interruption arrives while playing, and the only thing that
    /// authorises an automatic resume.
    private var wasInterruptedWhilePlaying = false
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

        // The raw values are pulled out *before* hopping to the main actor:
        // `Notification` is not `Sendable`, so it cannot cross the boundary, and the
        // two `UInt`s are all these handlers ever needed.
        observers.append(center.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let info = notification.userInfo
            let rawType = info?[AVAudioSessionInterruptionTypeKey] as? UInt
            let rawOptions = info?[AVAudioSessionInterruptionOptionKey] as? UInt

            MainActor.assumeIsolated {
                self?.handleInterruption(rawType: rawType, rawOptions: rawOptions)
            }
        })

        observers.append(center.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let rawReason = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt

            MainActor.assumeIsolated {
                self?.handleRouteChange(rawReason: rawReason)
            }
        })
    }

    private func handleInterruption(rawType: UInt?, rawOptions: UInt?) {
        guard let rawType,
              let type = AVAudioSession.InterruptionType(rawValue: rawType)
        else { return }

        switch type {
        case .began:
            // Latched **here**, before pausing. `onPause` runs the controller's own
            // `pause()`, which reports `noteIsPlaying(false)` -- so reading the play state
            // at `.ended` instead always saw false and auto-resume could never fire. That
            // is the whole reason an Instagram reel used to stop the music for good.
            //
            // No special case for `.appWasSuspended`: it was never followed by `.ended`
            // and iOS 16 stopped sending it at all.
            wasInterruptedWhilePlaying = isPlaying
            onPause?()

        case .ended:
            let options = rawOptions
                .map(AVAudioSession.InterruptionOptions.init(rawValue:)) ?? []

            guard options.contains(.shouldResume), wasInterruptedWhilePlaying else { return }
            resumeAfterInterruption()

        @unknown default:
            break
        }
    }

    private func handleRouteChange(rawReason: UInt?) {
        guard let rawReason,
              let reason = AVAudioSession.RouteChangeReason(rawValue: rawReason)
        else { return }

        // Headphones pulled out or an AirPod removed. Never auto-resume when a new
        // device appears -- that starts music in someone's pocket.
        if reason == .oldDeviceUnavailable {
            onPause?()
        }
    }

    /// Resumes when the interruption ended without the system saying so.
    ///
    /// `.ended` is not guaranteed: an app that never deactivates its own session leaves
    /// ours interrupted indefinitely, and coming back to the app is then the only signal
    /// there is. Gated on the same latch, and on nothing else currently holding the
    /// speaker, so this can never start music the user did not ask for.
    func resumeIfInterruptionWentUnreported() {
        guard wasInterruptedWhilePlaying,
              !AVAudioSession.sharedInstance().isOtherAudioPlaying
        else { return }
        resumeAfterInterruption()
    }

    private func resumeAfterInterruption() {
        wasInterruptedWhilePlaying = false
        // Reactivating *before* resuming is essential; skipping it is the classic cause
        // of playback that resumes but produces no sound.
        isActivated = false
        activate()
        onResume?()
    }

    func noteIsPlaying(_ isPlaying: Bool) {
        self.isPlaying = isPlaying
        // Playing again -- by any route -- settles the question, so a stale latch cannot
        // restart music minutes later.
        if isPlaying { wasInterruptedWhilePlaying = false }
    }
}
