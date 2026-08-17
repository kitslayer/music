import SwiftUI

@main
struct MusicApp: App {
    @State private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(appState)
                .preferredColorScheme(.dark)
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
