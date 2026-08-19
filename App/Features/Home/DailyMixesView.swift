import SwiftUI

/// Every mix, and more on the way down.
///
/// Home shows the same list sideways; this is the version you can keep scrolling. Both
/// read `DailyMixes`, so a mix built here is already there when you go back.
struct DailyMixesView: View {
    @Environment(AppState.self) private var appState
    @Environment(LibraryScopeStore.self) private var scope

    /// Shared with Home's shelf, so the choice is the same in both places.
    @AppStorage("mixes.folderID") private var mixFolderID = -1

    private var mixScope: LibraryScope {
        guard mixFolderID != -1,
              let folder = scope.folders.first(where: { $0.id == mixFolderID })
        else { return .all }
        return .folder(id: folder.id, name: folder.name)
    }

    var body: some View {
        List {
            ForEach(appState.mixes.mixes) { mix in
                NavigationLink(value: Destination.dailyMix(mix.id)) {
                    HStack(spacing: Metrics.itemSpacing) {
                        MixTile(covers: mix.covers, size: .thumb)
                            .frame(width: Metrics.thumbPlaylist, height: Metrics.thumbPlaylist)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(mix.title)
                                .lineLimit(1)
                            Text("\(mix.songs.count) songs · \(mix.subtitle)")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                }
            }

            if appState.mixes.canLoadMore {
                // The sentinel *is* the paging: it only exists when scrolled to, and it
                // cancels itself if you leave.
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Building more…")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .task { appState.mixes.loadMore(appState: appState, scope: mixScope) }
            }
        }
        .listStyle(.plain)
        .navigationTitle("Made for You")
        .toolbar {
            if scope.isSwitchable {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Picker("Library", selection: $mixFolderID) {
                            Text("Both Libraries").tag(-1)
                            ForEach(scope.folders) { folder in
                                Text(folder.name).tag(folder.id)
                            }
                        }
                    } label: {
                        Label(
                            mixFolderID == -1 ? "Both" : mixScope.shortName,
                            systemImage: "square.stack.3d.up"
                        )
                    }
                }
            }
        }
        .overlay {
            if appState.mixes.mixes.isEmpty, !appState.mixes.isBuilding {
                ContentUnavailableView(
                    "No Mixes Yet",
                    systemImage: "sparkles",
                    description: Text("Play a few things and these build themselves.")
                )
            }
        }
        .task(id: mixFolderID) {
            appState.mixes.load(appState: appState, scope: mixScope)
        }
    }
}
