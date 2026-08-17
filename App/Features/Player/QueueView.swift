import SwiftUI

struct QueueView: View {
    @Environment(AppState.self) private var appState

    private var player: PlaybackController { appState.player }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Playing Next")
                    .font(.headline)
                Spacer()
                if !player.queue.sourceDescription.isEmpty {
                    Text(player.queue.sourceDescription)
                        .font(.footnote)
                        .foregroundStyle(.white.opacity(0.6))
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 8)

            List {
                ForEach(Array(upNextWithIndices), id: \.song.id) { entry in
                    Button {
                        player.jump(toOrderIndex: entry.orderIndex)
                    } label: {
                        SongRow(song: entry.song, style: .withArtwork)
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(Color.clear)
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            player.removeFromQueue(orderIndex: entry.orderIndex)
                        } label: {
                            Label("Remove", systemImage: "minus.circle")
                        }
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .overlay {
                if player.queue.upNext.isEmpty {
                    Text("Nothing queued")
                        .font(.callout)
                        .foregroundStyle(.white.opacity(0.6))
                }
            }
        }
    }

    /// The order index is what the controller acts on, so carry it alongside.
    private var upNextWithIndices: [(orderIndex: Int, song: Song)] {
        let queue = player.queue
        let start = queue.position + 1
        guard start < queue.order.count else { return [] }

        return (start..<queue.order.count).map { index in
            (orderIndex: index, song: queue.tracks[queue.order[index]])
        }
    }
}
