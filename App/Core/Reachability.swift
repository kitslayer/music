import Network
import Observation

/// Whether there is any network at all.
///
/// Deliberately not "can we reach Navidrome": the server is on a home LAN, so a
/// reachability probe would be a request that fails slowly on cellular and succeeds
/// only at home. The useful signal is the interface state, which `NWPathMonitor`
/// gives instantly, plus the client's short timeout as the real arbiter.
///
/// It exists mainly to drive one behaviour that matters: flushing the scrobble outbox
/// the moment the phone gets a network back.
@MainActor
@Observable
final class Reachability {
    private(set) var isOnline = true
    /// True on cellular, so downloads can be held back if that is ever wanted.
    private(set) var isExpensive = false

    private let monitor = NWPathMonitor()
    /// Fired on every transition *into* online, which is the interesting edge.
    var onCameOnline: (() -> Void)?

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            let expensive = path.isExpensive

            Task { @MainActor in
                guard let self else { return }
                let wasOnline = self.isOnline
                self.isOnline = online
                self.isExpensive = expensive
                if online, !wasOnline { self.onCameOnline?() }
            }
        }
        monitor.start(queue: .global(qos: .utility))
    }

    deinit {
        monitor.cancel()
    }
}
