import SwiftUI

struct AlbumCard: View {
    let album: Album

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ArtworkImage(id: album.coverArt, size: .card)
                .aspectRatio(1, contentMode: .fit)

            Text(album.name)
                .font(.subheadline.weight(.medium))
                .lineLimit(1)

            if let artist = album.artist {
                Text(artist)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }
}

struct PlaylistCard: View {
    let playlist: Playlist

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ArtworkImage(id: playlist.coverArt, size: .card, playlistID: playlist.id)
                .aspectRatio(1, contentMode: .fit)

            Text(playlist.name)
                .font(.subheadline.weight(.medium))
                .lineLimit(1)

            if let count = playlist.songCount {
                Text("\(count) songs")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
