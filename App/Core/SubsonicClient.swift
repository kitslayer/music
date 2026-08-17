import CryptoKit
import Foundation

/// Talks to Navidrome over the Subsonic/OpenSubsonic API.
///
/// Everything the app knows about the library comes through here. Play counts,
/// ratings and playlists deliberately live on the server rather than in the app,
/// so the desktop client and this one stay in sync without either owning state.
actor SubsonicClient {
    struct Credentials: Codable, Equatable, Sendable {
        var baseURL: URL
        var username: String
        var password: String
    }

    enum ClientError: LocalizedError {
        case notConfigured
        case server(String)
        case transport(String)

        var errorDescription: String? {
            switch self {
            case .notConfigured:
                return "No server configured."
            case let .server(message):
                return message
            case let .transport(message):
                return message
            }
        }
    }

    private let session: URLSession
    private var credentials: Credentials?

    init(session: URLSession = .shared) {
        self.session = session
    }

    func configure(_ credentials: Credentials?) {
        self.credentials = credentials
    }

    // MARK: - Requests

    /// Subsonic auth is a per-request salted MD5 of the password. MD5 is only
    /// used because the protocol mandates it; it is not protecting anything we
    /// choose. A fresh salt per request avoids replaying a fixed token.
    private func url(for endpoint: String, query: [String: String?] = [:]) throws -> URL {
        guard let credentials else { throw ClientError.notConfigured }

        let salt = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12)
        let token = Insecure.MD5
            .hash(data: Data((credentials.password + salt).utf8))
            .map { String(format: "%02x", $0) }
            .joined()

        var components = URLComponents(
            url: credentials.baseURL.appendingPathComponent("rest/\(endpoint)"),
            resolvingAgainstBaseURL: false
        )

        var items = [
            URLQueryItem(name: "u", value: credentials.username),
            URLQueryItem(name: "t", value: token),
            URLQueryItem(name: "s", value: String(salt)),
            URLQueryItem(name: "v", value: "1.16.1"),
            URLQueryItem(name: "c", value: "NavidromeiOS"),
            URLQueryItem(name: "f", value: "json"),
        ]
        items.append(contentsOf: query.compactMap { key, value in
            value.map { URLQueryItem(name: key, value: $0) }
        })

        components?.queryItems = items

        guard let url = components?.url else { throw ClientError.notConfigured }
        return url
    }

    private func get<T: Decodable>(
        _ endpoint: String,
        query: [String: String?] = [:],
        as _: T.Type
    ) async throws -> T {
        let url = try url(for: endpoint, query: query)

        let data: Data
        do {
            (data, _) = try await session.data(from: url)
        } catch {
            throw ClientError.transport(error.localizedDescription)
        }

        let envelope: Envelope<T>
        do {
            envelope = try JSONDecoder().decode(Envelope<T>.self, from: data)
        } catch {
            throw ClientError.server("Unexpected response from server.")
        }

        if let error = envelope.subsonicResponse.error {
            throw ClientError.server(error.message)
        }

        guard let payload = envelope.subsonicResponse.payload else {
            throw ClientError.server("Server returned no data.")
        }

        return payload
    }

    // MARK: - Endpoints

    /// Cheap round trip used to validate credentials during setup. Decodes only
    /// the envelope status, since ping carries no payload of its own.
    func ping() async throws {
        let url = try url(for: "ping.view")

        let data: Data
        do {
            (data, _) = try await session.data(from: url)
        } catch {
            throw ClientError.transport(error.localizedDescription)
        }

        struct StatusOnly: Decodable {
            struct Inner: Decodable {
                let status: String?
                let error: SubsonicError?
            }

            let subsonicResponse: Inner

            enum CodingKeys: String, CodingKey {
                case subsonicResponse = "subsonic-response"
            }
        }

        guard let decoded = try? JSONDecoder().decode(StatusOnly.self, from: data) else {
            throw ClientError.server("That does not look like a Subsonic server.")
        }

        if let error = decoded.subsonicResponse.error {
            throw ClientError.server(error.message)
        }

        guard decoded.subsonicResponse.status == "ok" else {
            throw ClientError.server("Server rejected the credentials.")
        }
    }

    func albums(
        type: AlbumSort = .recent,
        size: Int = 100,
        offset: Int = 0
    ) async throws -> [Album] {
        let payload = try await get(
            "getAlbumList2.view",
            query: [
                "offset": String(offset),
                "size": String(size),
                "type": type.rawValue,
            ],
            as: AlbumList2.self
        )
        return payload.album ?? []
    }

    func albumDetail(id: String) async throws -> AlbumDetail {
        try await get("getAlbum.view", query: ["id": id], as: AlbumDetail.self)
    }

    /// Stream URL for playback. Returned rather than fetched so it can be handed
    /// straight to AVPlayer, which does its own ranged loading.
    func streamURL(for songID: String) throws -> URL {
        try url(for: "stream.view", query: ["id": songID])
    }

    func coverArtURL(for id: String?, size: Int? = nil) -> URL? {
        guard let id else { return nil }
        return try? url(
            for: "getCoverArt.view",
            query: ["id": id, "size": size.map(String.init)]
        )
    }
}

// MARK: - Response shapes

/// Subsonic wraps everything in `subsonic-response`, and names the payload
/// differently per endpoint, so each response type declares its own key.
private struct Envelope<T: Decodable>: Decodable {
    let subsonicResponse: Response<T>

    enum CodingKeys: String, CodingKey {
        case subsonicResponse = "subsonic-response"
    }
}

private struct Response<T: Decodable>: Decodable {
    let error: SubsonicError?
    let payload: T?

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: AnyKey.self)
        error = try container.decodeIfPresent(SubsonicError.self, forKey: AnyKey("error"))

        if let key = T.self as? PayloadKeyed.Type {
            payload = try container.decodeIfPresent(T.self, forKey: AnyKey(key.payloadKey))
        } else {
            payload = nil
        }
    }
}

private struct SubsonicError: Decodable {
    let code: Int
    let message: String
}

private struct AnyKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }

    init(_ stringValue: String) { self.stringValue = stringValue }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue _: Int) { nil }
}

/// Lets a payload type declare which key it lives under in the envelope.
protocol PayloadKeyed {
    static var payloadKey: String { get }
}
