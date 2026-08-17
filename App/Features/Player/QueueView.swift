import SwiftUI

struct QueueView: View {
    @Environment(AppState.self) private var appState

    @State private var isSavingAsPlaylist = false

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

                // A queue built by hand is the one thing in the app that exists
                // nowhere else, so it gets a way out to something permanent.
                Button {
                    isSavingAsPlaylist = true
                } label: {
                    Image(systemName: "text.badge.plus")
                        .foregroundStyle(.white.opacity(0.8))
                }
                .buttonStyle(.plain)
                .disabled(player.queue.tracks.isEmpty)
                .accessibilityLabel("Save queue as playlist")
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
                // Reordering is local, so it is free here -- unlike a server playlist,
                // where the API has no move operation at all.
                .onMove { source, destination in
                    guard let from = source.first else { return }
                    let start = player.queue.position + 1
                    player.moveInQueue(
                        from: start + from,
                        to: start + destination
                    )
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            // Always active: a queue is exactly the place where dragging to reorder is
            // expected without first tapping an Edit button.
            .environment(\.editMode, .constant(.active))
            .sheet(isPresented: $isSavingAsPlaylist) {
                NewPlaylistSheet(
                    songs: player.queue.order.compactMap { index in
                        player.queue.tracks.indices.contains(index)
                            ? player.queue.tracks[index]
                            : nil
                    },
                    suggestedName: player.queue.sourceDescription
                )
            }
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
