import SwiftUI

struct SongRow: View {
    @Environment(UserStateStore.self) private var userState

    enum Style {
        /// Album detail: track number, no artwork, no album line.
        case numbered(Int)
        /// Playlists, search, favourites: artwork instead of a position number.
        case withArtwork
    }

    let song: Song
    var style: Style = .withArtwork
    var isCurrent = false

    var body: some View {
        HStack(spacing: Metrics.itemSpacing) {
            leading

            VStack(alignment: .leading, spacing: 2) {
                Text(song.title)
                    .lineLimit(1)
                    .foregroundStyle(isCurrent ? Color.appTint : .primary)

                if let subtitle {
                    Text(subtitle)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 8)

            DownloadedBadge(songID: song.id)

            if userState.isStarred(song) {
                Image(systemName: "star.fill")
                    .font(.caption)
                    .foregroundStyle(Color.appTint)
            }

            if let duration = song.duration {
                Text(duration.asDuration)
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
        }
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var leading: some View {
        switch style {
        case let .numbered(position):
            if isCurrent {
                // Free animation, no custom equaliser to maintain.
                Image(systemName: "waveform")
                    .symbolEffect(.variableColor.iterative)
                    .foregroundStyle(Color.appTint)
                    .frame(width: 24, alignment: .trailing)
            } else {
                Text("\(position)")
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .frame(width: 24, alignment: .trailing)
            }
        case .withArtwork:
            ArtworkImage(id: song.coverArt, size: .thumb, cornerRadius: Metrics.radiusThumb)
                .frame(width: Metrics.thumbSmall, height: Metrics.thumbSmall)
        }
    }

    private var subtitle: String? {
        switch style {
        case .numbered:
            return song.artist
        case .withArtwork:
            return [song.artist, song.album].compactMap { $0 }.joined(separator: " — ")
        }
    }
}
