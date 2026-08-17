import SwiftUI

/// One place for the numbers, so screens line up without each view inventing its
/// own spacing. Values are chosen to match the system's own list insets on iPhone:
/// a `ScrollView` screen and a `List` screen share the same left edge.
enum Metrics {
    // Horizontal gutter. 16 matches List's inset on iPhone.
    static let gutter: CGFloat = 16

    // Vertical rhythm
    static let shelfSpacing: CGFloat = 28
    static let headerToContent: CGFloat = 12
    static let itemSpacing: CGFloat = 12

    // Corner radii, all .continuous
    static let radiusThumb: CGFloat = 6
    static let radiusCard: CGFloat = 8
    static let radiusHeader: CGFloat = 10
    static let radiusPlayer: CGFloat = 12

    // Artwork sizes
    static let thumbSmall: CGFloat = 40
    static let thumbRow: CGFloat = 48
    static let thumbPlaylist: CGFloat = 56
    static let cardWidth: CGFloat = 160
    static let detailArtwork: CGFloat = 200

    // Rows
    static let rowCategory: CGFloat = 44
    static let rowTrack: CGFloat = 44
    static let rowSong: CGFloat = 56
    static let miniPlayerHeight: CGFloat = 56

    // Touch
    static let minimumTouchTarget: CGFloat = 44
}

extension Color {
    /// Single accent for the whole app. The player is the only place colour is
    /// derived from content.
    static let appTint = Color(red: 0.98, green: 0.28, blue: 0.36)
}
