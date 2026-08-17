import SwiftUI

enum PlayerMode: String, CaseIterable {
    case artwork, queue, lyrics
}

struct NowPlayingView: View {
    @Environment(AppState.self) private var appState
    @Environment(SleepTimer.self) private var sleepTimer
    @Environment(DownloadCenter.self) private var downloads
    @Environment(\.dismiss) private var dismiss

    @State private var mode: PlayerMode = .artwork
    @State private var scrubValue: Double?
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
                .gesture(dismissDrag)

            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                // Only in artwork mode: in queue and lyrics mode this area is a
                // scroller, and a drag gesture over it would steal the scroll.
                // `.subviews` is how a gesture is switched off -- there is no
                // `gesture(_:)` overload that takes an optional.
                .gesture(dismissDrag, including: mode == .artwork ? .all : .subviews)

            if let song = player.currentSong {
                VStack(spacing: 0) {
                    metadata(song)
                    detailLine(song)
                }
                .gesture(dismissDrag)

                seekBar
                transport
                volumeRow
                bottomRow
            }
        }
        .background(alignment: .top) { backdrop }
        .offset(y: dragOffset)
        // Shrinks slightly as it is pulled, which is what makes the drag read as
        // "putting it away" rather than sliding a page.
        .scaleEffect(1 - min(dragOffset / 3000, 0.06))
        .onAppear { dragOffset = 0 }
    }

    // MARK: - Dismissal

    /// `fullScreenCover` has no interactive dismiss of its own -- only `sheet` does --
    /// so the gesture is explicit. A sheet was the alternative and was rejected: it
    /// cannot go edge to edge, and this screen is mostly artwork.
    private var dismissDrag: some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { value in
                // Downward only. Dragging up is not a dismissal, and allowing it
                // would let the screen be pulled off the top.
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
    }

    private var source: String {
        let described = player.queue.sourceDescription
        return described.isEmpty ? "Queue" : described
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
        .padding(.top, 6)
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
            modeButton(.queue, "list.bullet")
            Spacer()
            AudioRoutePicker()
                .frame(width: Metrics.minimumTouchTarget, height: Metrics.minimumTouchTarget)
        }
        .padding(.horizontal, 32)
        .padding(.top, 4)
        .padding(.bottom, 4)
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
