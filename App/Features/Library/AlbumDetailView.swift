import SwiftUI

struct AlbumDetailView: View {
    @Environment(AppState.self) private var appState

    let album: AlbumRef

    @State private var detail: AlbumDetail?
    @State private var error: String?

    var body: some View {
        List {
            Section {
                header
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }

            if let error {
                Text(error)
                    .foregroundStyle(.red)
            }

            if detail?.hasMultipleDiscs == true {
                ForEach(discs, id: \.number) { disc in
                    Section("Disc \(disc.number)") {
                        songRows(disc.songs)
                    }
                }
            } else {
                songRows(songs)
            }
        }
        .listStyle(.plain)
        .collapsingTitle(album.name)
        .task { await load() }
    }

    private var songs: [Song] { detail?.songs ?? [] }

    private var discs: [(number: Int, songs: [Song])] {
        Dictionary(grouping: songs) { $0.discNumber ?? 1 }
            .map { (number: $0.key, songs: $0.value) }
            .sorted { $0.number < $1.number }
    }

    @ViewBuilder
    private func songRows(_ list: [Song]) -> some View {
        ForEach(Array(list.enumerated()), id: \.element.id) { index, song in
            Button {
                play(from: song)
            } label: {
                SongRow(
                    song: song,
                    style: .numbered(song.track ?? index + 1),
                    isCurrent: appState.player.currentSong?.id == song.id
                )
            }
            .buttonStyle(.plain)
            // Separators start at the title, not under the number column.
            .alignmentGuide(.listRowSeparatorLeading) { _ in 36 }
            .contextMenu {
                Button("Play Next", systemImage: "text.insert") {
                    appState.player.playNext([song])
                }
                Button("Add to Queue", systemImage: "text.append") {
                    appState.player.append([song])
                }
            }
        }
    }

    private func play(from song: Song) {
        let all = songs
        guard let index = all.firstIndex(where: { $0.id == song.id }) else { return }
        appState.player.play(songs: all, startingAt: index, source: album.name)
    }

    private var header: some View {
        VStack(spacing: Metrics.headerToContent) {
            ArtworkImage(id: album.coverArt, size: .full, cornerRadius: Metrics.radiusHeader)
                .aspectRatio(1, contentMode: .fit)
                .frame(maxWidth: Metrics.detailArtwork)
                .shadow(radius: 12, y: 6)

            VStack(spacing: 4) {
                Text(album.name)
                    .font(.title2.weight(.bold))
                    .multilineTextAlignment(.center)

                if let artist = album.artist ?? detail?.artist {
                    Text(artist)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }

            PlayShuffleButtons(
                onPlay: {
                    appState.player.play(songs: songs, startingAt: 0, source: album.name)
                },
                onShuffle: {
                    appState.player.play(
                        songs: songs, startingAt: 0, source: album.name, shuffled: true
                    )
                }
            )
            .padding(.horizontal, Metrics.gutter)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Metrics.gutter)
    }

    private var subtitle: String {
        var parts: [String] = []
        if let year = detail?.year { parts.append(String(year)) }
        if let count = detail?.songCount { parts.append("\(count) tracks") }
        if let duration = detail?.duration { parts.append(duration.asLongDuration) }
        return parts.joined(separator: " · ")
    }

    private func load() async {
        do {
            detail = try await appState.client.albumDetail(id: album.id)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}
