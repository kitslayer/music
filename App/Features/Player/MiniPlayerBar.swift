import SwiftUI

/// The bar above the tab bar. The whole thing is the tap target.
struct MiniPlayerBar: View {
    @Environment(AppState.self) private var appState
    @Binding var showsPlayer: Bool

    private var player: PlaybackController { appState.player }

    var body: some View {
        if let song = player.currentSong {
            VStack(spacing: 0) {
                Divider()

                HStack(spacing: Metrics.itemSpacing) {
                    ArtworkImage(
                        id: song.coverArt,
                        size: .thumb,
                        cornerRadius: Metrics.radiusThumb
                    )
                    .frame(width: Metrics.thumbSmall, height: Metrics.thumbSmall)

                    // One line only: 56pt with two lines is cramped, and the artist
                    // is one tap away in the full player.
                    Text(song.title)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)

                    Spacer(minLength: 8)

                    Button {
                        player.togglePlayPause()
                    } label: {
                        Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                            .font(.title3)
                            .frame(width: Metrics.minimumTouchTarget, height: Metrics.minimumTouchTarget)
                    }
                    .buttonStyle(.plain)

                    Button {
                        player.next()
                    } label: {
                        Image(systemName: "forward.fill")
                            .font(.title3)
                            .frame(width: Metrics.minimumTouchTarget, height: Metrics.minimumTouchTarget)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, Metrics.gutter)
                .frame(height: Metrics.miniPlayerHeight)
                .background(.ultraThinMaterial)
                .contentShape(Rectangle())
                .onTapGesture { showsPlayer = true }
                // Swipe up to expand, sideways to skip -- the gestures Plexamp and
                // Apple Music both use.
                .gesture(
                    DragGesture(minimumDistance: 20)
                        .onEnded { value in
                            if value.translation.height < -30 {
                                showsPlayer = true
                            } else if value.translation.width < -50 {
                                player.next()
                            } else if value.translation.width > 50 {
                                player.previous()
                            }
                        }
                )
                .overlay(alignment: .bottom) { progressLine }
            }
        }
    }

    /// Reads the controller's 4 Hz elapsed value; a 2pt line needs nothing finer.
    private var progressLine: some View {
        GeometryReader { geometry in
            let fraction = player.duration > 0
                ? min(max(player.elapsed / player.duration, 0), 1)
                : 0
            Rectangle()
                .fill(Color.appTint)
                .frame(width: geometry.size.width * fraction, height: 2)
        }
        .frame(height: 2)
    }
}
