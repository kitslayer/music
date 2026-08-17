import SwiftUI

struct SettingsView: View {
    @Environment(AppState.self) private var appState
    @Environment(LibraryScopeStore.self) private var scope

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
