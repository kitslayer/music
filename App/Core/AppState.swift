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
    /// Synchronous URL builder for media endpoints, held here so the player and the
    /// artwork cache can build URLs without awaiting the client actor.
    private(set) var signer: SubsonicSigner?

    let client = SubsonicClient()
    let artwork = ArtworkStore()
    let scope = LibraryScopeStore()
    let userState = UserStateStore()
    let downloads = DownloadCenter()
    let reachability = Reachability()
    let outbox = ServerOutbox()
    let sleepTimer = SleepTimer()
    let player = PlaybackController()

    init() {
        // Directories must exist before anything touches disk, and before a
        // background download session can be relaunched into.
        Paths.bootstrap()
        userState.configure(client: client)
        downloads.attach(appState: self)
        player.attach(appState: self)

        sleepTimer.onFire = { [weak self] in
            self?.player.fadeOutAndPause()
        }

        // Plays recorded while offline reach the server the moment there is one.
        reachability.onCameOnline = { [weak self] in
            Task { await self?.flushOutbox() }
        }

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
        signer = await client.makeSigner()
        artwork.configure(signer: signer)
        phase = .ready

        await player.restore()
        await flushOutbox()
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
        signer = await client.makeSigner()
        artwork.configure(signer: signer)
        phase = .ready

        await loadServerContext()
    }

    func signOut() async {
        Keychain.clear()
        credentials = nil
        signer = nil
        await client.configure(nil)
        artwork.configure(signer: nil)
        userState.reset()
        phase = .needsSetup
    }

    /// Called at launch, on foreground, and on regaining a network. Cheap when the
    /// outbox is empty, which is the normal case.
    func flushOutbox() async {
        guard credentials != nil else { return }
        _ = await outbox.flush(using: client)
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
