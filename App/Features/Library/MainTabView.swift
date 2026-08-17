import SwiftUI

/// Three tabs, because each is a different *way of finding* music: recommended,
/// owned, named. A fourth tab would be a destination rather than a mode, which is
/// why Downloads and Settings live inside Library and Home instead.
struct MainTabView: View {
    var body: some View {
        TabView {
            Tab("Home", systemImage: "house") {
                HomeView()
            }

            Tab("Library", systemImage: "square.stack") {
                LibraryHubView()
            }

            Tab(role: .search) {
                SearchView()
            }
        }
    }
}
