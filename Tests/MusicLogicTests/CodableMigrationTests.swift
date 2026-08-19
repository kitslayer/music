import Foundation
import Testing

/// Pins the language behaviour that a persisted-model bug in this app depended on.
///
/// `ServerOutbox.Pending` carried `var kind: Kind = .scrobble` with a comment claiming the
/// default let older files decode. It does not. Swift's synthesized `init(from:)` calls
/// `decode(_:forKey:)` for every non-optional property and throws when the key is missing,
/// whatever default is written — and the outbox **deletes** files it cannot decode, so
/// plays that were owed to the server were being discarded instead of migrated.
///
/// `ServerOutbox` itself cannot be tested here: it depends on `SubsonicClient`, which is not
/// in this target. These mirrors reproduce the two shapes exactly, so the rule is enforced
/// even though the real type lives elsewhere.
struct CodableMigrationTests {
    private struct Defaulted: Codable {
        var kind: String = "scrobble"
        let songID: String
    }

    private struct OptionalBacked: Codable {
        private var kind_: String?
        let songID: String

        var kind: String { kind_ ?? "scrobble" }

        enum CodingKeys: String, CodingKey {
            case kind_ = "kind"
            case songID
        }
    }

    /// A file written before the field existed.
    private var legacy: Data { Data(#"{"songID":"abc"}"#.utf8) }

    @Test func aDefaultValueDoesNotSurviveAMissingKey() {
        // If this ever starts passing, Swift changed and the workaround can be simplified.
        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(Defaulted.self, from: legacy)
        }
    }

    @Test func anOptionalDoesSurviveAMissingKey() throws {
        let decoded = try JSONDecoder().decode(OptionalBacked.self, from: legacy)
        #expect(decoded.songID == "abc")
        #expect(decoded.kind == "scrobble")
    }

    @Test func anOptionalStillReadsThePresentValue() throws {
        let current = Data(#"{"kind":"rating","songID":"abc"}"#.utf8)
        let decoded = try JSONDecoder().decode(OptionalBacked.self, from: current)
        #expect(decoded.kind == "rating")
    }
}
