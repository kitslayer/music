import SwiftUI

enum PlayerMode: String, CaseIterable {
    case artwork, queue, lyrics, visualizer
}

struct NowPlayingView: View {
    @Environment(AppState.self) private var appState
    @Environment(SleepTimer.self) private var sleepTimer
    @Environment(DownloadCenter.self) private var downloads
    @Environment(\.dismiss) private var dismiss

    @State private var mode: PlayerMode = .artwork
    @State private var dragOffset: CGFloat = 0
    @Namespace private var modeNamespace

    private var player: PlaybackController { appState.player }

    var body: some View {
        // Its own stack: without one, the artist name and the menu's "Go to Album" are
        // links with nowhere to push, which is to say dead. Browsing from inside the
        // player is also what Plexamp does.
        NavigationStack {
            playerBody
                .toolbar(.hidden, for: .navigationBar)
                .musicDestinations()
        }
    }

    private var playerBody: some View {
        VStack(spacing: 0) {
            topBar

            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            if let song = player.currentSong {
                // The title block is its own drag surface in *every* mode, including
                // queue and lyrics. It is the natural place to grab from and it never
                // scrolls, so nothing competes for the gesture here.
                VStack(spacing: 0) {
                    metadata(song)
                    detailLine(song)
                }
                .contentShape(Rectangle())
                .gesture(dismissDrag)

                PlayerSeekBar()
                transport
                volumeRow
                bottomRow
            }
        }
        // `contentShape` is the fix for "it only works on the album art": empty layout
        // space in a stack is not hit-testable, so a drag starting to the right of the
        // title was landing on nothing at all. The artwork worked only because an image
        // is opaque. This makes the whole screen a drag surface.
        .contentShape(Rectangle())
        // Masked off in the scrolling modes, where the queue and lyrics own the vertical
        // pan; the top bar and the title block carry the gesture there instead.
        .gesture(dismissDrag, including: isScrollingMode ? .subviews : .all)
        .background(alignment: .top) { backdrop }
        // Offset only. A scale on top of this meant recompositing the blurred backdrop
        // at a new size every frame, and the drag has to track the finger exactly or it
        // reads as broken.
        .offset(y: dragOffset)
        .onAppear { dragOffset = 0 }
    }

    // MARK: - Dismissal

    /// `fullScreenCover` has no interactive dismiss of its own -- only `sheet` does --
    /// so the gesture is explicit. A sheet was the alternative and was rejected: it
    /// cannot go edge to edge, and this screen is mostly artwork.
    private var dismissDrag: some Gesture {
        DragGesture(minimumDistance: 18)
            .onChanged { value in
                // Vertical drags only. A sideways swipe is not a dismissal, and tracking
                // it made the screen twitch whenever a horizontal gesture began.
                guard abs(value.translation.height) > abs(value.translation.width) else {
                    return
                }
                // Downward only: allowing up would let the screen be pulled off the top.
                dragOffset = max(0, value.translation.height)
            }
            .onEnded { value in
                // Distance *or* speed, so a quick flick works without travelling far.
                let isFarEnough = value.translation.height > 130
                let isFastEnough = value.predictedEndTranslation.height > 320

                if isFarEnough || isFastEnough {
                    dismiss()
                } else {
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
                        dragOffset = 0
                    }
                }
            }
    }

    /// A visible close button as well as the gesture: the previous version had only a
    /// 5pt capsule that happened to be tappable, which is not an affordance.
    /// Queue and lyrics own the vertical scroll, so a full-screen drag would fight
    /// them. The visualiser and artwork do not scroll, so there it can cover everything.
    private var isScrollingMode: Bool {
        mode == .queue || mode == .lyrics
    }

    private var topBar: some View {
        HStack(spacing: Metrics.itemSpacing) {
            Button {
                dismiss()
            } label: {
                Image(systemName: "chevron.down")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.8))
                    .frame(width: Metrics.minimumTouchTarget, height: Metrics.minimumTouchTarget)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Close player")

            VStack(spacing: 1) {
                Text("Playing From")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.5))
                Text(source)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)

            if let song = player.currentSong {
                Menu {
                    SongMenu(song: song)
                    Divider()
                    SleepTimerMenu()
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.8))
                        .frame(
                            width: Metrics.minimumTouchTarget,
                            height: Metrics.minimumTouchTarget
                        )
                        .contentShape(Rectangle())
                }
            } else {
                Spacer().frame(width: Metrics.minimumTouchTarget)
            }
        }
        .padding(.horizontal, 8)
        .contentShape(Rectangle())
        .gesture(dismissDrag, including: isScrollingMode ? .all : .subviews)
    }

    private var source: String {
        let described = player.queue.sourceDescription
        return described.isEmpty ? "Queue" : described
    }

    /// Blurred artwork behind everything: the only place colour comes from content.
    ///
    /// `drawingGroup()` is not decoration. A 60pt blur over a full-screen image was
    /// being recomputed on every frame of the dismiss drag, which is what made the
    /// gesture stutter. Flattened into one texture, moving it is nearly free.
    private var backdrop: some View {
        ArtworkImage(id: player.currentSong?.coverArt, size: .full, cornerRadius: 0)
            .aspectRatio(contentMode: .fill)
            .frame(maxWidth: .infinity)
            .blur(radius: 60, opaque: true)
            .overlay(.black.opacity(0.45))
            .drawingGroup()
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

            case .visualizer:
                VisualizerView()
            }
        }
        .animation(.easeInOut(duration: 0.25), value: mode)
    }

    private func metadata(_ song: Song) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(song.title)
                    .font(.title3.weight(.bold))
                    .lineLimit(1)

                // Tappable, because "who is this" is the most common next question and
                // the menu is two taps away.
                if let artist = song.artist {
                    if let artistId = song.artistId {
                        NavigationLink(value: Destination.artist(
                            ArtistRef(id: artistId, name: artist)
                        )) {
                            artistLabel(artist)
                        }
                        .buttonStyle(.plain)
                    } else {
                        artistLabel(artist)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            FavoriteButton(id: song.id, kind: .song, serverValue: song.isFavorite)
                .font(.title3)
                .frame(width: 36, height: 36)
        }
        .padding(.horizontal, 24)
        .padding(.top, Metrics.itemSpacing)
        .contentShape(Rectangle())
    }

    private func artistLabel(_ artist: String) -> some View {
        Text(artist)
            .font(.title3)
            .foregroundStyle(.white.opacity(0.7))
            .lineLimit(1)
    }

    /// The quiet line Plexamp gets right: what you are actually hearing, and where you
    /// are in the queue. Every part is omitted when unknown rather than shown as a
    /// placeholder.
    private func detailLine(_ song: Song) -> some View {
        HStack(spacing: 6) {
            if downloads.isDownloaded(song.id) {
                Label("Downloaded", systemImage: "arrow.down.circle.fill")
                    .labelStyle(.iconOnly)
                    .foregroundStyle(Color.appTint)
            }

            Text(qualityText(song))

            if player.queue.order.count > 1 {
                Text("·")
                Text("\(player.queue.position + 1) of \(player.queue.order.count)")
                    .monospacedDigit()
            }

            if let label = sleepTimer.label {
                Text("·")
                Label(label, systemImage: "moon.fill")
                    .foregroundStyle(Color.appTint)
            }

            Spacer(minLength: 0)
        }
        .font(.caption2)
        .foregroundStyle(.white.opacity(0.55))
        .padding(.horizontal, 24)
        .padding(.top, 5)
    }

    private func qualityText(_ song: Song) -> String {
        var parts: [String] = []
        if let suffix = song.suffix { parts.append(suffix.uppercased()) }
        // Lossless bitrates are variable and the reported number is an average, so it
        // is more honest to show the container alone than a precise-looking figure.
        if let rate = song.bitRate, rate > 0, song.suffix?.lowercased() != "flac" {
            parts.append("\(rate) kbps")
        }
        return parts.isEmpty ? "Streaming" : parts.joined(separator: " · ")
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
        .padding(.top, Metrics.itemSpacing)
    }

    /// The system slider, flanked by the usual two icons so it reads as volume rather
    /// than a second progress bar.
    private var volumeRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "speaker.fill")
            SystemVolumeSlider()
            Image(systemName: "speaker.wave.3.fill")
        }
        .font(.caption2)
        .foregroundStyle(.white.opacity(0.5))
        .padding(.horizontal, 24)
        .padding(.top, Metrics.itemSpacing)
    }

    private var bottomRow: some View {
        HStack {
            modeButton(.lyrics, "quote.bubble")
            Spacer()
            modeButton(.artwork, "photo")
            Spacer()
            modeButton(.visualizer, "waveform")
            Spacer()
            modeButton(.queue, "list.bullet")
            Spacer()
            AudioRoutePicker()
                .frame(width: Metrics.minimumTouchTarget, height: Metrics.minimumTouchTarget)
        }
        .padding(.horizontal, 20)
        .padding(.top, 4)
        .padding(.bottom, 4)
    }

    /// Selection is shown by tint and weight, not by swapping in a `.fill` variant.
    /// Appending ".fill" was a guess that does not hold: `waveform.fill` and
    /// `list.bullet.fill` are not real symbols, and an unknown name renders as blank.
    private func modeButton(_ target: PlayerMode, _ symbol: String) -> some View {
        let isSelected = mode == target

        return Button {
            mode = isSelected ? .artwork : target
        } label: {
            Image(systemName: symbol)
                .font(.title3.weight(isSelected ? .bold : .regular))
                .foregroundStyle(isSelected ? Color.appTint : .white.opacity(0.6))
                .frame(width: Metrics.minimumTouchTarget, height: Metrics.minimumTouchTarget)
        }
    }
}

/// Its own view on purpose. It reads `elapsed`, which ticks four times a second, and
/// under `@Observable` that invalidates whatever view read it -- so inside the player's
/// body it was re-rendering the entire screen, blurred backdrop included, 4x/second.
/// Scoped here, the tick repaints a slider and two labels.
private struct PlayerSeekBar: View {
    @Environment(AppState.self) private var appState

    @State private var scrubValue: Double?

    private var player: PlaybackController { appState.player }

    var body: some View {
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
        .padding(.top, 6)
    }
}

/// Lives in the player's overflow menu rather than in Settings: it is a thing you
/// reach for while already listening in bed, not something you configure.
struct SleepTimerMenu: View {
    @Environment(SleepTimer.self) private var timer

    var body: some View {
        Menu {
            if timer.isArmed {
                Button("Turn Off", systemImage: "moon.slash") {
                    timer.cancel()
                }
                Divider()
            }

            Button("End of Track", systemImage: "music.note") {
                timer.armEndOfTrack()
            }

            ForEach([15, 30, 45, 60, 90], id: \.self) { minutes in
                Button("\(minutes) Minutes") {
                    timer.arm(minutes: minutes)
                }
            }
        } label: {
            Label(
                timer.label.map { "Sleep Timer — \($0)" } ?? "Sleep Timer",
                systemImage: timer.isArmed ? "moon.fill" : "moon"
            )
        }
    }
}
