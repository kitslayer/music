import Observation
import UIKit

/// Keeps the screen on while the app is in front.
///
/// `isIdleTimerDisabled` is the whole mechanism, but two details decide whether it is a
/// feature or a flat battery. It is a **per-app** flag that iOS ignores while the app is
/// backgrounded, so it can never keep someone's phone awake in a pocket. And it has to be
/// re-applied when the app comes back, because the system clears it on the way out — a
/// setting that silently stops working after one trip to Instagram is worse than no
/// setting.
///
/// The preference persists: someone who reads lyrics with the phone propped up wants that
/// to still be true tomorrow, and the toggle is in the player's own menu where it is
/// visible rather than buried in Settings.
@MainActor
@Observable
final class ScreenAwake {
    private let key = "screen.keepAwake"

    var isEnabled: Bool {
        didSet {
            guard isEnabled != oldValue else { return }
            UserDefaults.standard.set(isEnabled, forKey: key)
            apply()
        }
    }

    init() {
        isEnabled = UserDefaults.standard.bool(forKey: key)
    }

    /// Call when the app becomes active. Idempotent.
    func apply() {
        UIApplication.shared.isIdleTimerDisabled = isEnabled
    }

    /// Call when the app leaves the foreground. iOS does this itself, but doing it
    /// explicitly means the flag's state always matches what we asked for.
    func release() {
        UIApplication.shared.isIdleTimerDisabled = false
    }
}
