import SwiftUI

@main
struct MusicApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase

    @State private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(appState)
                .environment(appState.artwork)
                .environment(appState.playlistArtwork)
                .environment(appState.scope)
                .environment(appState.userState)
                .environment(appState.playlistStore)
                .environment(appState.requests)
                .environment(appState.queueSync)
                .environment(appState.playlistSync)
                .environment(appState.downloads)
                .environment(appState.reachability)
                .environment(appState.sleepTimer)
                .environment(appState.audio)
                .environment(appState.spectrum)
                .preferredColorScheme(.dark)
                .tint(.appTint)
                .onChange(of: scenePhase) { _, phase in
                    switch phase {
                    case .active:
                        // Coming back is the most likely moment to have a network
                        // again after listening offline.
                        Task { await appState.flushOutbox() }
                        Task { await appState.refreshRequests() }
                        Task { await appState.playlistSync.sync() }
                        Task {
                            await appState.queueSync.check(
                                localSavedAt: appState.player.lastSavedAt
                            )
                        }
                    case .background:
                        // Backgrounding does not kill the app while audio plays, but
                        // termination while paused is common and silent.
                        appState.player.persistNow()
                    default:
                        break
                    }
                }
        }
    }
}

struct RootView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        switch appState.phase {
        case .loading:
            ProgressView()
                .controlSize(.large)
        case .needsSetup:
            ServerSetupView()
        case .ready:
            MainTabView()
        }
    }
}
