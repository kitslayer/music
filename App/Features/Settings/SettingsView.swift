import SwiftUI

struct SettingsView: View {
    @Environment(AppState.self) private var appState
    @Environment(LibraryScopeStore.self) private var scope
    @Environment(AudioSettings.self) private var audio
    @Environment(DownloadCenter.self) private var downloads
    @Environment(MusicRequestService.self) private var requests
    @Environment(PlaylistSync.self) private var playlistSync

    @State private var testResult: String?
    @State private var isTesting = false

    var body: some View {
        Form {
            if let credentials = appState.credentials {
                Section("Server") {
                    LabeledContent("Address", value: credentials.baseURL.absoluteString)
                    LabeledContent("User", value: credentials.username)

                    Button {
                        Task { await test() }
                    } label: {
                        HStack {
                            Text("Test Connection")
                            Spacer()
                            if isTesting {
                                ProgressView()
                            } else if let testResult {
                                Text(testResult)
                                    .font(.footnote)
                                    .foregroundStyle(testResult == "OK" ? .green : .red)
                            }
                        }
                    }
                }
            }

            if scope.isSwitchable {
                Section {
                    // The same store as the toolbar control: a mirror, not a
                    // second source of truth.
                    Picker("Show", selection: Binding(
                        get: { scope.scope },
                        set: { scope.scope = $0 }
                    )) {
                        ForEach(scope.options, id: \.self) { option in
                            Text(option.shortName).tag(option)
                        }
                    }
                } header: {
                    Text("Library")
                } footer: {
                    Text("Applies to Home, Albums, Artists, Genres and Search. Playlists always show every library.")
                }
            }

            Section {
                NavigationLink(value: Destination.audioSettings) {
                    LabeledContent("Audio", value: audioSummary)
                }
                NavigationLink(value: Destination.downloads) {
                    LabeledContent("Downloads", value: downloadSummary)
                }
                NavigationLink(value: Destination.offlineSettings) {
                    LabeledContent("Offline & Library", value: offlineSummary)
                }
                NavigationLink(value: Destination.requestSettings) {
                    LabeledContent(
                        "Music Requests",
                        value: requests.isConfigured ? "Connected" : "Not set up"
                    )
                }
            }

            Section("About") {
                LabeledContent("Version", value: version)
            }

            Section {
                Button("Sign Out", role: .destructive) {
                    Task { await appState.signOut() }
                }
            }
        }
        .navigationTitle("Settings")
    }

    private var audioSummary: String {
        guard audio.isEnabled else { return "Gapless" }
        if audio.crossfadeSeconds > 0 { return "Crossfade \(Int(audio.crossfadeSeconds))s" }
        return audio.isFlat ? "Gapless" : audio.presetName
    }

    private var offlineSummary: String {
        playlistSync.isEnabled ? "Playlists kept offline" : "Manual"
    }

    private var downloadSummary: String {
        let count = downloads.catalog.entries.count
        return count == 0 ? "None" : "\(count) · \(downloads.catalog.totalBytes.asFileSize)"
    }

    private var version: String {
        let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }

    private func test() async {
        isTesting = true
        testResult = nil
        do {
            try await appState.client.ping()
            testResult = "OK"
        } catch {
            testResult = error.localizedDescription
        }
        isTesting = false
    }
}
