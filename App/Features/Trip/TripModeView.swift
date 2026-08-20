import SwiftUI

/// Packing music for a trip.
///
/// This screen exists because the honest answer to "download some music for the flight" is
/// arithmetic: at the library's own quality, five days is about 54 GB. Rather than let
/// someone find that out one album at a time, the numbers are shown up front — including
/// how much of the trip is already on the phone, which is usually more than expected.
struct TripModeView: View {
    @Environment(AppState.self) private var appState
    @Environment(LibraryScopeStore.self) private var scope
    @Environment(DownloadCenter.self) private var downloads

    @State private var model = TripModeModel()
    @State private var didStart = false

    var body: some View {
        Form {
            Section("How long") {
                Stepper("\(model.days) \(model.days == 1 ? "day" : "days")", value: $model.days, in: 1...21)
                Stepper(
                    "\(model.hoursPerDay) \(model.hoursPerDay == 1 ? "hour" : "hours") a day",
                    value: $model.hoursPerDay,
                    in: 1...12
                )
                LabeledContent("Music needed", value: model.targetText)
            }

            Section {
                Picker("Quality", selection: $model.quality) {
                    ForEach(DownloadQuality.allCases) { quality in
                        Text(quality.label).tag(quality)
                    }
                }
                .pickerStyle(.segmented)

                Text(model.quality.detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Quality")
            } footer: {
                // The trade, stated rather than implied.
                Text("Original is what this app normally downloads. The other three are transcoded by the server on the way out, which is the only way a long trip fits.")
            }

            planSection

            if !model.plan.groups.isEmpty {
                Section {
                    ForEach(model.plan.groups) { group in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(group.name).lineLimit(1)
                            Text("\(group.songs.count) songs\(group.subtitle.map { " · \($0)" } ?? "")")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                } header: {
                    Text("What gets packed")
                }
            }
        }
        .navigationTitle("Trip Mode")
        .playerClearance()
        .overlay {
            if model.isLoading, model.groups.isEmpty { ProgressView() }
        }
        .task {
            guard !didStart else { return }
            didStart = true
            await model.load(appState: appState, scope: scope.scope)
        }
        // Re-planning is pure arithmetic on already-fetched songs, so it can run on every
        // change of the steppers without touching the network.
        .onChange(of: model.days) { model.replan(downloads: downloads) }
        .onChange(of: model.hoursPerDay) { model.replan(downloads: downloads) }
        .onChange(of: model.quality) { model.replan(downloads: downloads) }
        .onChange(of: downloads.catalog.entries.count) { model.replan(downloads: downloads) }
    }

    @ViewBuilder
    private var planSection: some View {
        Section {
            LabeledContent("Songs", value: "\(model.plan.songCount)")
            LabeledContent("Playing time", value: model.plan.seconds.asLongDuration)
            LabeledContent("Already downloaded", value: "\(model.plan.alreadyCount) songs")
            LabeledContent("To download", value: model.plan.bytesToDownload.asFileSize)
            LabeledContent("Free space", value: model.freeBytes.asFileSize)

            if model.plan.isSpaceLimited {
                Label(
                    "Some of it was left out — there isn't room at this quality.",
                    systemImage: "exclamationmark.triangle"
                )
                .font(.footnote)
                .foregroundStyle(.orange)
            }

            Button {
                model.pack(appState: appState)
            } label: {
                Label(
                    model.plan.toDownload.isEmpty
                        ? "Already packed"
                        : "Download \(model.plan.toDownload.count) songs",
                    systemImage: "arrow.down.circle.fill"
                )
            }
            .disabled(model.plan.toDownload.isEmpty)
        } header: {
            Text("The plan")
        } footer: {
            Text("Built from your favourites, today's mixes and what you play most — whole albums where it can, and never the same recording twice.")
        }
    }
}

@MainActor
@Observable
final class TripModeModel {
    var days = 3
    var hoursPerDay = 3
    /// Not `original`: at the library's own quality a trip of any length does not fit, and
    /// a default that never works is not a default.
    var quality: DownloadQuality = .standard

    private(set) var groups: [TripPlanner.Group] = []
    private(set) var plan = TripPlanner.Plan()
    private(set) var isLoading = false
    private(set) var freeBytes: Int64 = 0

    var targetText: String {
        TripPlanner.targetSeconds(days: days, hoursPerDay: hoursPerDay).asLongDuration
    }

    func load(appState: AppState, scope: LibraryScope) async {
        isLoading = true
        defer { isLoading = false }

        freeBytes = Paths.availableBytes
        var gathered: [TripPlanner.Group] = []

        // Today's mixes first: they are already in memory, and they are the closest thing
        // the app has to "what this person wants to hear right now".
        for mix in appState.mixes.mixes {
            gathered.append(TripPlanner.Group(
                id: "mix-\(mix.id)", name: mix.title, subtitle: mix.subtitle, songs: mix.songs
            ))
        }

        if let starred = try? await appState.client.starred(scope: scope), !starred.songs.isEmpty {
            gathered.append(TripPlanner.Group(
                id: "favourites", name: "Favourites", subtitle: "Starred", songs: starred.songs
            ))
        }

        // Whole albums, because three tracks off a record is a worse thing to find on a
        // plane than the record. One request each, so this is capped rather than paged.
        let albums = (try? await appState.client.albums(type: .frequent, size: 12, scope: scope)) ?? []
        for album in albums {
            guard let detail = try? await appState.client.albumDetail(id: album.id) else { continue }
            gathered.append(TripPlanner.Group(
                id: album.id, name: album.name, subtitle: album.artist, songs: detail.songs
            ))
        }

        groups = gathered
        replan(downloads: appState.downloads)
    }

    func replan(downloads: DownloadCenter) {
        freeBytes = Paths.availableBytes
        plan = TripPlanner.plan(
            groups: groups,
            downloaded: Set(downloads.catalog.entries.keys),
            targetSeconds: TripPlanner.targetSeconds(days: days, hoursPerDay: hoursPerDay),
            quality: quality,
            freeBytes: freeBytes
        )
    }

    func pack(appState: AppState) {
        for group in plan.groups {
            appState.downloads.download(
                group.songs,
                groupID: group.id,
                groupName: group.name,
                quality: quality
            )
        }
        replan(downloads: appState.downloads)
    }
}
