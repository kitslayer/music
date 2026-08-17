import Foundation
import SwiftUI

/// Holds the session: which server we are signed in to, and the client that
/// talks to it. Credentials live in the Keychain rather than UserDefaults
/// because they are a real password, not a preference.
@MainActor
@Observable
final class AppState {
    enum Phase: Equatable {
        case loading
        case needsSetup
        case ready
    }

    private(set) var phase: Phase = .loading
    private(set) var credentials: SubsonicClient.Credentials?

    let client = SubsonicClient()

    init() {
        Task { await restore() }
    }

    /// Restores a saved session on launch. A stored credential is trusted
    /// without a round trip so the library is browsable immediately -- and, once
    /// offline support lands, without a network at all.
    func restore() async {
        guard let saved = Keychain.loadCredentials() else {
            phase = .needsSetup
            return
        }

        credentials = saved
        await client.configure(saved)
        phase = .ready
    }

    /// Verifies credentials against the server before storing them, so a typo
    /// surfaces at the setup screen instead of as an empty library later.
    func signIn(baseURL: URL, username: String, password: String) async throws {
        let candidate = SubsonicClient.Credentials(
            baseURL: baseURL,
            username: username,
            password: password
        )

        await client.configure(candidate)

        do {
            try await client.ping()
        } catch {
            await client.configure(credentials)
            throw error
        }

        Keychain.save(candidate)
        credentials = candidate
        phase = .ready
    }

    func signOut() async {
        Keychain.clear()
        credentials = nil
        await client.configure(nil)
        phase = .needsSetup
    }
}
