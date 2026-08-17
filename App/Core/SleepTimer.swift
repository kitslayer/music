import Foundation
import Observation

/// Stops playback after a while, or at the end of the current track.
///
/// Deliberately a wall-clock deadline rather than a countdown that gets decremented:
/// the app is suspended for most of the time the timer is running, so a tick-based
/// countdown would silently stall and the music would never stop. A stored `Date` is
/// correct however long the process was frozen.
///
/// The fade matters more than it sounds: cutting audio dead at 30:00 will wake you up,
/// which defeats the entire purpose.
@MainActor
@Observable
final class SleepTimer {
    enum Mode: Equatable, Sendable {
        case off
        case at(Date)
        /// Stop when the track that is playing now finishes.
        case endOfTrack
    }

    private(set) var mode: Mode = .off

    /// Set by whoever owns playback; the timer itself knows nothing about audio.
    var onFire: (() -> Void)?

    private var task: Task<Void, Never>?

    var isArmed: Bool { mode != .off }

    /// Nil when not armed. Recomputed on read rather than stored, so it stays right
    /// across suspension.
    var remaining: TimeInterval? {
        guard case let .at(deadline) = mode else { return nil }
        return max(0, deadline.timeIntervalSinceNow)
    }

    var label: String? {
        switch mode {
        case .off:
            return nil
        case .endOfTrack:
            return "End of track"
        case .at:
            guard let remaining else { return nil }
            let minutes = Int(remaining / 60) + (remaining.truncatingRemainder(dividingBy: 60) > 0 ? 1 : 0)
            return minutes <= 1 ? "1 min" : "\(minutes) min"
        }
    }

    func arm(minutes: Int) {
        cancel()
        let deadline = Date.now.addingTimeInterval(TimeInterval(minutes) * 60)
        mode = .at(deadline)

        task = Task { [weak self] in
            // One sleep to the deadline, not a loop: nothing needs to happen in
            // between, and a repeating timer would keep waking a sleeping phone.
            try? await Task.sleep(for: .seconds(deadline.timeIntervalSinceNow))
            guard !Task.isCancelled else { return }
            self?.fire()
        }
    }

    func armEndOfTrack() {
        cancel()
        mode = .endOfTrack
    }

    func cancel() {
        task?.cancel()
        task = nil
        mode = .off
    }

    /// Called by the player when a track finishes, so `.endOfTrack` can act on the
    /// only event that defines it.
    func trackDidFinish() {
        guard mode == .endOfTrack else { return }
        fire()
    }

    private func fire() {
        mode = .off
        task = nil
        onFire?()
    }
}
