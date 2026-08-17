import SwiftUI

/// Ask for music the library does not have.
///
/// The request goes to the Hermes agent, which searches Soulseek, verifies the transfer
/// actually landed, and reports back on its own channel. So this screen is deliberately
/// not a progress view: it can honestly say "sent", and nothing more. Claiming to track
/// a download it cannot see would be the worse lie.
struct MusicRequestView: View {
    @Environment(MusicRequestService.self) private var requests

    /// Prefilled when arriving from a search that found nothing.
    var initialText: String = ""

    @State private var text = ""
    @State private var didSend = false
    @FocusState private var isFocused: Bool

    var body: some View {
        Form {
            if requests.isConfigured {
                Section {
                    TextField("Artist — Album", text: $text, axis: .vertical)
                        .lineLimit(1...3)
                        .focused($isFocused)
                        .submitLabel(.send)
                        .onSubmit(send)

                    Button {
                        send()
                    } label: {
                        HStack {
                            Text("Send Request")
                            Spacer()
                            if requests.isSending { ProgressView() }
                        }
                    }
                    .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty || requests.isSending)
                } header: {
                    Text("What do you want?")
                } footer: {
                    if let error = requests.lastError {
                        Text(error).foregroundStyle(.red)
                    } else if didSend {
                        Text("Sent. Hermes will search Soulseek and report back — it usually replies on Discord.")
                            .foregroundStyle(Color.appTint)
                    } else {
                        Text("An artist and album is enough. Hermes checks the library first so it will not fetch something you already have.")
                    }
                }

                if !requests.history.isEmpty {
                    Section {
                        ForEach(requests.history) { entry in
                            HStack(spacing: Metrics.itemSpacing) {
                                Image(systemName: entry.wasAccepted
                                    ? "checkmark.circle.fill"
                                    : "exclamationmark.triangle.fill")
                                    .foregroundStyle(entry.wasAccepted ? Color.appTint : .orange)

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(entry.text).lineLimit(2)
                                    Text(entry.sentAt.formatted(date: .abbreviated, time: .shortened))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    } header: {
                        Text("Sent")
                    } footer: {
                        // Said once, so a tick is not mistaken for "it arrived".
                        Text("A tick means the gateway accepted the request, not that the music arrived.")
                    }

                    Section {
                        Button("Clear History", role: .destructive) {
                            requests.clearHistory()
                        }
                    }
                }
            } else {
                Section {
                    ContentUnavailableView(
                        "Not Set Up",
                        systemImage: "antenna.radiowaves.left.and.right.slash",
                        description: Text(
                            "Add the Hermes webhook address and secret in Settings to request music from here."
                        )
                    )
                }
            }
        }
        .navigationTitle("Request Music")
        .onAppear {
            if text.isEmpty { text = initialText }
            isFocused = requests.isConfigured && text.isEmpty
        }
    }

    private func send() {
        let outgoing = text
        Task {
            if await requests.send(outgoing) {
                didSend = true
                text = ""
            }
        }
    }
}

/// The webhook setup, in Settings. Separate from the request screen because it is
/// configured once and then never looked at again.
struct MusicRequestSettingsView: View {
    @Environment(MusicRequestService.self) private var requests

    @State private var address = ""
    @State private var secret = ""
    @State private var problem: String?

    var body: some View {
        Form {
            Section {
                TextField("http://192.168.1.148:8644/webhooks/music-request", text: $address)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)

                SecureField("HMAC secret", text: $secret)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            } header: {
                Text("Hermes Webhook")
            } footer: {
                if let problem {
                    Text(problem).foregroundStyle(.red)
                } else {
                    Text("""
                    The secret is kept in the Keychain on this phone. Requests are signed \
                    with it, and the gateway rejects anything unsigned or older than five \
                    minutes.
                    """)
                }
            }

            Section {
                Button("Save") { save() }
                    .disabled(address.isEmpty || secret.isEmpty)

                if requests.isConfigured {
                    Button("Remove", role: .destructive) {
                        requests.forget()
                        address = ""
                        secret = ""
                    }
                }
            }
        }
        .navigationTitle("Music Requests")
        .onAppear {
            if let configuration = requests.configuration {
                address = configuration.endpoint.absoluteString
                // The secret is never shown back: it is write-only from here, which is
                // what a secret field should be.
                secret = ""
            }
        }
    }

    private func save() {
        guard let url = URL(string: address), url.scheme != nil, url.host != nil else {
            problem = "That does not look like a URL."
            return
        }
        problem = nil
        requests.configure(endpoint: url, secret: secret)
    }
}
