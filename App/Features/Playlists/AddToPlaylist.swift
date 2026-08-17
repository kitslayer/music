import SwiftUI

/// "Add to Playlist" as a submenu, offered wherever a song or a set of songs is.
///
/// A menu rather than a sheet: adding a track to a playlist you already have should be
/// two taps, and a modal for that is the kind of friction that makes people stop
/// bothering. Creating a *new* playlist does need a sheet, because it needs a keyboard.
struct AddToPlaylistMenu: View {
    @Environment(PlaylistStore.self) private var store

    let songs: [Song]
    /// Shown in the "New Playlist…" sheet as the suggested name.
    var suggestedName: String = ""

    @State private var isNaming = false

    var body: some View {
        Menu("Add to Playlist", systemImage: "text.badge.plus") {
            Button("New Playlist…", systemImage: "plus") {
                isNaming = true
            }

            if !store.playlists.isEmpty {
                Divider()
                ForEach(store.playlists) { playlist in
                    Button(playlist.name) {
                        Task { await store.add(songs, to: playlist) }
                    }
                }
            }
        }
        // The menu is populated before it is opened, so it never shows an empty list
        // and then fills in under the finger.
        .task { await store.loadIfNeeded() }
        .modifier(NamingSheet(isPresented: $isNaming, songs: songs, suggested: suggestedName))
    }
}

/// A `ViewModifier` because a `Menu`'s content is not a view hierarchy that can host a
/// sheet -- attaching it to the menu itself is what makes it present.
private struct NamingSheet: ViewModifier {
    @Environment(PlaylistStore.self) private var store

    @Binding var isPresented: Bool
    let songs: [Song]
    let suggested: String

    func body(content: Content) -> some View {
        content.sheet(isPresented: $isPresented) {
            NewPlaylistSheet(songs: songs, suggestedName: suggested)
        }
    }
}

struct NewPlaylistSheet: View {
    @Environment(PlaylistStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    let songs: [Song]
    var suggestedName: String = ""

    @State private var name = ""
    @State private var isSaving = false
    @FocusState private var isFocused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Playlist name", text: $name)
                        .focused($isFocused)
                        .submitLabel(.done)
                        .onSubmit(save)
                } footer: {
                    if songs.isEmpty {
                        Text("An empty playlist you can add to later.")
                    } else {
                        Text("\(songs.count) \(songs.count == 1 ? "song" : "songs") will be added.")
                    }
                }
            }
            .navigationTitle("New Playlist")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create", action: save)
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || isSaving)
                }
            }
            .onAppear {
                name = suggestedName
                isFocused = true
            }
        }
        // Short, because it is one field. A full-height sheet for one text field looks
        // like something went wrong.
        .presentationDetents([.height(220)])
    }

    private func save() {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        isSaving = true
        Task {
            await store.create(name: name, songs: songs)
            dismiss()
        }
    }
}

/// Rename / edit the description of an existing playlist.
struct EditPlaylistSheet: View {
    @Environment(PlaylistStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    let playlist: Playlist

    @State private var name: String
    @State private var comment: String

    init(playlist: Playlist) {
        self.playlist = playlist
        _name = State(initialValue: playlist.name)
        _comment = State(initialValue: playlist.comment ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    TextField("Playlist name", text: $name)
                }
                Section("Description") {
                    TextField("Optional", text: $comment, axis: .vertical)
                        .lineLimit(1...4)
                }
            }
            .navigationTitle("Edit Playlist")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        Task {
                            await store.rename(
                                playlist,
                                to: name,
                                comment: comment.isEmpty ? nil : comment
                            )
                            dismiss()
                        }
                    }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }
}
