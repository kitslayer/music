import CryptoKit
import Foundation
import Observation

/// Sends "please get me this album" to the Hermes agent, which acquires it over
/// Soulseek and puts it in the library.
///
/// The gateway authenticates with HMAC-SHA256 over `"<timestamp>.<body>"` and rejects
/// anything more than five minutes old — its V2 scheme. The older V1 signs the body
/// alone, which means a captured request replays forever, so this only ever sends V2.
///
/// The shared secret is entered on device and kept in the Keychain, never in the
/// repository: this repo is public, and a committed secret is a committed secret
/// whether or not the port is LAN-only.
@MainActor
@Observable
final class MusicRequestService {
    struct Configuration: Codable, Sendable, Equatable {
        /// Full route URL, e.g. `http://192.168.1.148:8644/webhooks/music-request`.
        var endpoint: URL
        var secret: String
    }

    /// One sent request, kept locally so the screen can show what was asked for. The
    /// agent reports progress on its own channel; this is a record, not a status.
    struct Entry: Codable, Sendable, Identifiable {
        var id = UUID()
        var text: String
        var sentAt: Date
        var wasAccepted: Bool
    }

    private(set) var configuration: Configuration?
    private(set) var history: [Entry] = []
    private(set) var isSending = false
    var lastError: String?

    private let historyKey = "musicRequest.history"

    var isConfigured: Bool { configuration != nil }

    init() {
        configuration = Keychain.loadMusicRequestConfiguration()
        if let data = UserDefaults.standard.data(forKey: historyKey),
           let decoded = try? JSONDecoder().decode([Entry].self, from: data) {
            history = decoded
        }
    }

    func configure(endpoint: URL, secret: String) {
        let configuration = Configuration(endpoint: endpoint, secret: secret)
        Keychain.saveMusicRequestConfiguration(configuration)
        self.configuration = configuration
        lastError = nil
    }

    func forget() {
        Keychain.clearMusicRequestConfiguration()
        configuration = nil
    }

    /// Returns true when the gateway accepted it. Acceptance means "queued for the
    /// agent", not "found" — this is a request, and the answer comes back through
    /// Hermes rather than here.
    @discardableResult
    func send(_ text: String) async -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let configuration else { return false }

        isSending = true
        lastError = nil
        defer { isSending = false }

        let payload: [String: String] = [
            "request": trimmed,
            "source": "Music iOS",
        ]
        guard let body = try? JSONSerialization.data(withJSONObject: payload) else {
            lastError = "Could not encode the request"
            return false
        }

        let timestamp = String(Int(Date.now.timeIntervalSince1970))
        let signed = Data(timestamp.utf8) + Data(".".utf8) + body
        let signature = HMAC<SHA256>
            .authenticationCode(for: signed, using: SymmetricKey(data: Data(configuration.secret.utf8)))
            .map { String(format: "%02x", $0) }
            .joined()

        var request = URLRequest(url: configuration.endpoint)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(timestamp, forHTTPHeaderField: "X-Webhook-Timestamp")
        request.setValue(signature, forHTTPHeaderField: "X-Webhook-Signature-V2")
        // The agent takes a while to answer, but acceptance is immediate; a long
        // timeout here would only hide a misconfigured endpoint.
        request.timeoutInterval = 15

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let accepted = (200...299).contains(status)

            if !accepted {
                lastError = status == 401
                    ? "The gateway rejected the signature — check the secret."
                    : "The gateway replied \(status)."
            }

            record(Entry(text: trimmed, sentAt: .now, wasAccepted: accepted))
            return accepted
        } catch {
            lastError = error.localizedDescription
            record(Entry(text: trimmed, sentAt: .now, wasAccepted: false))
            return false
        }
    }

    func clearHistory() {
        history = []
        UserDefaults.standard.removeObject(forKey: historyKey)
    }

    private func record(_ entry: Entry) {
        // Newest first, capped: this is a memory aid, not a log.
        history.insert(entry, at: 0)
        history = Array(history.prefix(30))
        if let data = try? JSONEncoder().encode(history) {
            UserDefaults.standard.set(data, forKey: historyKey)
        }
    }
}
