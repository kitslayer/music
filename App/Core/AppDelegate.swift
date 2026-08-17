import UIKit

/// Exists for exactly one callback that SwiftUI has no equivalent for:
/// `handleEventsForBackgroundURLSession`.
///
/// When downloads finish while the app is not running, iOS relaunches it in the
/// background purely to deliver those events, hands over a completion handler, and
/// expects it to be called once the session says it is done. An app that fails to
/// call it gets relaunched less and less often — so downloads degrade quietly rather
/// than visibly, which is the worst possible failure mode for this feature.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        BackgroundSessionBridge.pendingCompletion = completionHandler
    }
}

/// A static hand-off, because the relaunch can arrive before any `AppState` exists —
/// there is nothing to inject into yet, and the session that will report the events
/// is recreated from its identifier rather than from anything the UI owns.
@MainActor
enum BackgroundSessionBridge {
    static var pendingCompletion: (() -> Void)?

    static func finish() {
        let handler = pendingCompletion
        pendingCompletion = nil
        handler?()
    }
}
