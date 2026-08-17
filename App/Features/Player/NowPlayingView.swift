import SwiftUI

enum PlayerMode: String, CaseIterable {
    case artwork, queue, lyrics
}

struct NowPlayingView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    @State private var mode: PlayerMode = .artwork
    @State private var scrubValue: Double?
    @Namespace private var modeNamespace

    private var player: PlaybackController { appState.player }

    var body: some View {
        VStack(spacing: 0) {
            grabber

            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            if let song = player.currentSong {
                metadata(song)
                seekBar
                transport
                modeSwitcher
            }
        }
        .background(alignment: .top) { backdrop }
        .presentationDragIndicator(.hidden)
    }

    private var grabber: some View {
        Capsule()
            .fill(.white.opacity(0.3))
            .frame(width: 36, height: 5)
            .padding(.top, 8)
            .padding(.bottom, 4)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
            .onTapGesture { dismiss() }
    }

    /// Blurred artwork behind everything: the only place colour comes from content.
    private var backdrop: some View {
        ArtworkImage(id: player.currentSong?.coverArt, size: .full, cornerRadius: 0)
            .aspectRatio(contentMode: .fill)
            .frame(maxWidth: .infinity)
            .blur(radius: 60, opaque: true)
            .overlay(.black.opacity(0.45))
            .ignoresSafeArea()
    }

    @ViewBuilder
    private var content: some View {
        ZStack {
            switch mode {
            case .artwork:
                ArtworkImage(
                    id: player.currentSong?.coverArt,
                    size: .full,
                    cornerRadius: Metrics.radiusPlayer
                )
                .aspectRatio(1, contentMode: .fit)
                .padding(.horizontal, 24)
                .shadow(radius: 24, y: 12)
                // One small motion cue that makes the screen feel alive.
                .scaleEffect(player.isPlaying ? 1 : 0.86)
                .animation(.spring(duration: 0.35), value: player.isPlaying)
                .matchedGeometryEffect(id: "artwork", in: modeNamespace)

            case .queue:
                QueueView()

            case .lyrics:
                if let song = player.currentSong {
                    LyricsView(song: song)
                }
            }
        }
        .animation(.easeInOut(duration: 0.25), value: mode)
    }

    private func metadata(_ song: Song) -> some View {
        VStack(spacing: 2) {
            Text(song.title)
                .font(.title3.weight(.bold))
                .lineLimit(1)
            Text(song.artist ?? "")
                .font(.title3)
                .foregroundStyle(.white.opacity(0.7))
                .lineLimit(1)
        }
        .padding(.horizontal, 24)
        .padding(.top, Metrics.itemSpacing)
    }

    private var seekBar: some View {
        VStack(spacing: 2) {
            Slider(
                value: Binding(
                    get: { scrubValue ?? player.elapsed },
                    set: { scrubValue = $0 }
                ),
                in: 0...max(player.duration, 1),
                onEditingChanged: { editing in
                    // Commit on release rather than seeking continuously.
                    if !editing, let value = scrubValue {
                        player.seek(to: value)
                        scrubValue = nil
                    }
                }
            )

            HStack {
                Text(Int(scrubValue ?? player.elapsed).asDuration)
                Spacer()
                Text(Int(max(player.duration - (scrubValue ?? player.elapsed), 0)).asDuration)
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.white.opacity(0.6))
        }
        .padding(.horizontal, 24)
        .padding(.top, 8)
    }

    private var transport: some View {
        HStack(spacing: 28) {
            Button { player.toggleShuffle() } label: {
                Image(systemName: "shuffle")
                    .foregroundStyle(player.queue.isShuffled ? Color.appTint : .white.opacity(0.7))
            }

            Button { player.previous() } label: {
                Image(systemName: "backward.fill").font(.title2)
            }

            Button { player.togglePlayPause() } label: {
                Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 56))
            }

            Button { player.next() } label: {
                Image(systemName: "forward.fill").font(.title2)
            }

            Button { player.cycleRepeat() } label: {
                Image(systemName: player.queue.repeatMode.symbol)
                    .foregroundStyle(
                        player.queue.repeatMode == .off ? .white.opacity(0.7) : Color.appTint
                    )
            }
        }
        .foregroundStyle(.white)
        .padding(.top, Metrics.gutter)
    }

    private var modeSwitcher: some View {
        HStack(spacing: 44) {
            modeButton(.lyrics, "quote.bubble")
            modeButton(.artwork, "photo")
            modeButton(.queue, "list.bullet")
        }
        .padding(.top, Metrics.gutter)
        .padding(.bottom, 8)
    }

    private func modeButton(_ target: PlayerMode, _ symbol: String) -> some View {
        Button {
            mode = mode == target ? .artwork : target
        } label: {
            Image(systemName: mode == target ? "\(symbol).fill" : symbol)
                .font(.title3)
                .foregroundStyle(mode == target ? Color.appTint : .white.opacity(0.6))
                .frame(width: Metrics.minimumTouchTarget, height: Metrics.minimumTouchTarget)
        }
    }
}
