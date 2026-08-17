import SwiftUI

/// Top-level navigation. A real `TabView` rather than a hand-built bar, so it
/// gets the system's height, blur, safe-area handling and scroll-to-top for free.
struct MainTabView: View {
    var body: some View {
        TabView {
            Tab("Albums", systemImage: "square.stack") {
                AlbumListView()
            }

            Tab("Settings", systemImage: "gearshape") {
                SettingsView()
            }
        }
    }
}

struct SettingsView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        NavigationStack {
            List {
                if let credentials = appState.credentials {
                    Section("Server") {
                        LabeledContent("Address", value: credentials.baseURL.absoluteString)
                        LabeledContent("User", value: credentials.username)
                    }
                }

                Section {
                    Button("Sign out", role: .destructive) {
                        Task { await appState.signOut() }
                    }
                }
            }
            .navigationTitle("Settings")
        }
    }
}
