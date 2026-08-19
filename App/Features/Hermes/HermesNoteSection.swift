import SwiftUI

/// A written note about a record or an artist, from Hermes.
///
/// This fills a hole that is visible on the artist page today: `getArtistInfo2` returns no
/// biography from this server and the images it points at 404, so an artist screen is a
/// grid of albums and nothing else.
///
/// Written once and cached to disk. Deliberately `load`/`store` rather than
/// `LibraryCache.value(for:fetch:)` — that helper is fetch-first, which is right for a
/// library listing that changes and exactly wrong for a note that costs an agent run and
/// never changes. Failures are never cached: a note that failed once should be askable
/// again, not remembered as "nothing".
struct HermesNoteSection: View {
    @Environment(AppState.self) private var appState

    let subject: HermesNoteSubject
    /// The artist header shows one paragraph; the album screen shows the lot.
    var isCompact = false

    @State private var note: HermesNote?
    @State private var isAsking = false
    @State private var failure: String?

    var body: some View {
        Group {
            if let note, let text = displayText(note) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(text)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    if !isCompact, let sources = note.sources, !sources.isEmpty {
                        Text("Sources: \(sources.joined(separator: ", "))")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .lineLimit(2)
                    }
                }
            } else if isAsking {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Hermes is writing…")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } else if appState.hermes.isAvailable {
                Button {
                    Task { await ask() }
                } label: {
                    Label(
                        subject.kind == "album" ? "Ask Hermes about this album" : "Ask Hermes about this artist",
                        systemImage: "text.quote"
                    )
                    .font(.footnote)
                }
                .buttonStyle(.bordered)
            }
        }
        .overlay(alignment: .bottomLeading) {
            if let failure {
                Text(failure)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .task(id: subject) {
            note = await appState.cache.load(HermesNote.self, for: Self.cacheKey(subject))
        }
    }

    private func displayText(_ note: HermesNote) -> String? {
        let paragraphs = note.paragraphs
        guard !paragraphs.isEmpty else { return nil }
        return isCompact ? paragraphs[0] : paragraphs.joined(separator: "\n\n")
    }

    private func ask() async {
        isAsking = true
        failure = nil
        defer { isAsking = false }

        let outcome = await appState.hermes.ask(
            route: "music-notes",
            fields: [
                "kind": subject.kind,
                "name": subject.name,
                "artist": subject.artist ?? "",
            ],
            as: HermesNote.self,
            // A couple of paragraphs and maybe a web search. Long enough to be worth
            // waiting on the screen for, which is why this one polls in the foreground.
            timeout: 150
        )

        switch outcome {
        case let .ok(written):
            note = written
            await appState.cache.store(written, for: Self.cacheKey(subject))
        case let .failed(message):
            failure = message
        case .pending:
            failure = "Hermes is taking longer than usual — try again in a minute."
        }
    }

    static func cacheKey(_ subject: HermesNoteSubject) -> String {
        "note-\(subject.kind)-\(subject.id)"
    }
}
