import SwiftUI

/// Three tabs, because each is a different *way of finding* music: recommended,
/// owned, named. A fourth tab would be a destination rather than a mode, which is
/// why Downloads and Settings live inside Library and Home instead.
struct MainTabView: View {
    @Environment(PlaylistStore.self) private var playlistStore

    @State private var showsPlayer = false

    var body: some View {
        Group {
            if #available(iOS 26.0, *) {
                tabs
                    // The system's own slot for exactly this. It reserves the space
                    // itself, which a hand-rolled `safeAreaInset` did not do reliably
                    // -- the bar was covering the bottom of some screens.
                    .tabViewBottomAccessory {
                        MiniPlayerBar(showsPlayer: $showsPlayer, isSystemAccessory: true)
                    }
            } else {
                tabs
            }
        }
        .fullScreenCover(isPresented: $showsPlayer) {
            NowPlayingView()
        }
        .overlay(alignment: .bottom) { toast }
        .animation(.snappy(duration: 0.25), value: playlistStore.lastMessage)
    }

    /// Added a song to a playlist? Say so. Menus give no feedback of their own, so
    /// without this the action is indistinguishable from nothing happening.
    @ViewBuilder
    private var toast: some View {
        if let message = playlistStore.lastMessage {
            Text(message)
                .font(.footnote.weight(.medium))
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(.regularMaterial, in: Capsule())
                .shadow(radius: 8, y: 2)
                .padding(.bottom, 120)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .task(id: message) {
                    try? await Task.sleep(for: .seconds(2.2))
                    playlistStore.lastMessage = nil
                }
        }
    }

    private var tabs: some View {
        TabView {
            Tab("Home", systemImage: "house") {
                hosted { HomeView() }
            }

            Tab("Library", systemImage: "square.stack") {
                hosted { LibraryHubView() }
            }

            Tab(role: .search) {
                hosted { SearchView() }
            }
        }
    }

    /// Before iOS 26 there is no accessory slot, so the bar is inset into each tab.
    /// It has to be *inside* the tab rather than on the `TabView`: inside a tab the tab
    /// bar is already part of the safe area, so the bar lands directly above it and
    /// every scroll view in that tab gets the extra bottom inset. Applied to the
    /// `TabView` it renders underneath the tab bar instead.
    @ViewBuilder
    private func hosted<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        if #available(iOS 26.0, *) {
            content()
        } else {
            content()
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    MiniPlayerBar(showsPlayer: $showsPlayer)
                }
        }
    }
}
