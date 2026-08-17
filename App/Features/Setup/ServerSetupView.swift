import SwiftUI

struct ServerSetupView: View {
    @Environment(AppState.self) private var appState

    @State private var address = ""
    @State private var username = ""
    @State private var password = ""
    @State private var error: String?
    @State private var isConnecting = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("192.168.1.10:4533", text: $address)
                        .textContentType(.URL)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("Username", text: $username)
                        .textContentType(.username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("Password", text: $password)
                        .textContentType(.password)
                } header: {
                    Text("Navidrome server")
                } footer: {
                    Text("Host and port. http:// is assumed unless you type https://.")
                }

                if let error {
                    Section {
                        Text(error)
                            .foregroundStyle(.red)
                            .font(.callout)
                    }
                }

                Section {
                    Button(action: connect) {
                        if isConnecting {
                            HStack(spacing: 8) {
                                ProgressView()
                                Text("Connecting…")
                            }
                        } else {
                            Text("Connect")
                        }
                    }
                    .disabled(!canConnect || isConnecting)
                }
            }
            .navigationTitle("Set up")
        }
    }

    private var canConnect: Bool {
        !address.trimmingCharacters(in: .whitespaces).isEmpty && !username.isEmpty
    }

    /// Accepts a bare `host:port` as well as a full URL, because typing a scheme
    /// on a phone keyboard is friction for no benefit on a LAN server.
    private func normalizedURL() -> URL? {
        var text = address.trimmingCharacters(in: .whitespaces)
        if !text.contains("://") {
            text = "http://" + text
        }
        while text.hasSuffix("/") {
            text.removeLast()
        }
        return URL(string: text)
    }

    private func connect() {
        guard let url = normalizedURL() else {
            error = "That address is not valid."
            return
        }

        error = nil
        isConnecting = true

        Task {
            do {
                try await appState.signIn(baseURL: url, username: username, password: password)
            } catch {
                self.error = error.localizedDescription
            }
            isConnecting = false
        }
    }
}
