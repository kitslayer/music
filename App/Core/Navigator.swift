import Foundation
import Observation
import SwiftUI

/// Opening something from inside the player.
///
/// The player is a full-screen layer over the whole app, and it carries its own
/// `NavigationStack` so that "Go to Album" has somewhere to push at all. But pushing
/// *there* lands you on an album screen with no tab bar and no player bar — the app's
/// chrome is above you, under the layer you are standing on, and the only way back is a
/// swipe that also throws away the screen you just opened.
///
/// So a jump out of the player is not a push: it closes the player and opens the
/// destination in the Library tab, which is where albums and artists live and where both
/// bars exist. That is what Apple Music does, and it is the only version of this that
/// leaves you somewhere you can navigate from.
@MainActor
@Observable
final class Navigator {
    /// Whether the full-screen player is up. Owned here rather than in `MainTabView`
    /// because closing it is half of what opening a destination means.
    var showsPlayer = false

    /// The Library tab's stack, so a destination can be pushed into it from anywhere.
    var libraryPath = NavigationPath()

    /// Set when a jump wants the Library tab selected. Read once by the tab view.
    private(set) var wantsLibraryTab = false

    /// Closes the player and pushes `destination` in the Library tab.
    func open(_ destination: Destination) {
        showsPlayer = false
        wantsLibraryTab = true
        libraryPath.append(destination)
    }

    func didSelectLibraryTab() {
        wantsLibraryTab = false
    }
}
