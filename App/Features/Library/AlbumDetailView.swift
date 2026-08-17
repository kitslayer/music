import SwiftUI

struct AlbumDetailView: View {
    @Environment(AppState.self) private var appState
    let album: Album

    @State private var detail: AlbumDetail?
    @State private var error: String?

    var body: some View {
        List {
            Section {
                header
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
            }

            if let error {
                Text(error)
                    .foregroundStyle(.red)
            }

            // A plain List section, so rows scroll the header away for free --
            // no scroll-linked collapse logic and nothing pinned in the way.
            ForEach(Array(songs.enumerated()), id: \.element.id) { index, song in
                SongRow(song: song, position: index + 1)
            }
        }
        .listStyle(.plain)
        .navigationTitle(album.name)
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    private var songs: [Song] { detail?.songs ?? [] }

    private var header: some View {
        VStack(spacing: 12) {
            CoverArt(id: album.coverArt, size: 600)
                .aspectRatio(1, contentMode: .fit)
                .frame(maxWidth: 240)
                .clipShape(RoundedRectangle(cornerRadius: 10))

            VStack(spacing: 4) {
                Text(album.name)
                    .font(.title3.weight(.semibold))
                    .multilineTextAlignment(.center)

                if let artist = album.artist {
                    Text(artist)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
    }

    private var subtitle: String {
        var parts: [String] = []
        if let year = album.year { parts.append(String(year)) }
        let count = detail?.songCount ?? album.songCount
        if let count { parts.append("\(count) tracks") }
        if let duration = detail?.duration ?? album.duration {
            parts.append(duration.asDuration)
        }
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

struct SongRow: View {
    let song: Song
    let position: Int

    var body: some View {
        HStack(spacing: 12) {
            Text("\(position)")
                .font(.footnote.monospacedDigit())
                .foregroundStyle(.tertiary)
                .frame(width: 24, alignment: .trailing)

            VStack(alignment: .leading, spacing: 2) {
                Text(song.title)
                    .lineLimit(1)
                if let artist = song.artist {
                    Text(artist)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 8)

            if let duration = song.duration {
                Text(duration.asDuration)
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
        }
        .contentShape(Rectangle())
    }
}
