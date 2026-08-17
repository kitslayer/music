import Foundation
import Observation

/// Composition root: owns the session and every long-lived store, and hands them
/// to SwiftUI through the environment. Deliberately not a singleton -- everything
/// is injected so there is one place to see what the app is made of.
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
    let artwork = ArtworkStore()
    let scope = LibraryScopeStore()

    init() {
        Task { await restore() }
    }

    /// Restores a saved session on launch. A stored credential is trusted without a
    /// round trip, so the app reaches `.ready` with no network at all -- which is
    /// what lets downloaded music play offline from a cold launch.
    func restore() async {
        guard let saved = Keychain.loadCredentials() else {
            phase = .needsSetup
            return
        }

        credentials = saved
        await client.configure(saved)
        artwork.configure(signer: await client.makeSigner())
        phase = .ready

        await loadServerContext()
    }

    /// Verifies credentials against the server before storing them, so a typo
    /// surfaces at the setup screen rather than as an empty library later.
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
        artwork.configure(signer: await client.makeSigner())
        phase = .ready

        await loadServerContext()
    }

    func signOut() async {
        Keychain.clear()
        credentials = nil
        await client.configure(nil)
        artwork.configure(signer: nil)
        phase = .needsSetup
    }

    /// Best-effort: neither the folder list nor the capability list is worth
    /// blocking the UI on, and both are absent when offline.
    private func loadServerContext() async {
        await client.loadCapabilities()

        if let folders = try? await client.musicFolders() {
            scope.adopt(folders: folders)
        }
    }
}
