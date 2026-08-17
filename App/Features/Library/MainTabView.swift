import SwiftUI

/// Three tabs, because each is a different *way of finding* music: recommended,
/// owned, named. A fourth tab would be a destination rather than a mode, which is
/// why Downloads and Settings live inside Library and Home instead.
struct MainTabView: View {
    @State private var showsPlayer = false

    var body: some View {
        TabView {
            Tab("Home", systemImage: "house") {
                HomeView()
                    .miniPlayer($showsPlayer)
            }

            Tab("Library", systemImage: "square.stack") {
                LibraryHubView()
                    .miniPlayer($showsPlayer)
            }

            Tab(role: .search) {
                SearchView()
                    .miniPlayer($showsPlayer)
            }
        }
        .fullScreenCover(isPresented: $showsPlayer) {
            NowPlayingView()
        }
    }
}

extension View {
    /// The bar has to be inset *inside* each tab, not on the `TabView`: inside a tab
    /// the tab bar is already part of the safe area, so the bar lands directly above
    /// it and every scroll view in that tab gets the extra bottom inset for free.
    /// Applied to the `TabView`, it renders underneath the tab bar instead.
    func miniPlayer(_ showsPlayer: Binding<Bool>) -> some View {
        safeAreaInset(edge: .bottom, spacing: 0) {
            MiniPlayerBar(showsPlayer: showsPlayer)
        }
    }
}
