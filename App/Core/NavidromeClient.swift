import Foundation

/// Navidrome's own API, used for the one thing Subsonic cannot answer: **when**.
///
/// Subsonic exposes a `playCount` and no dates for songs — `getAlbumList2?type=recent`
/// sorts *albums* by last play and that is the whole of it. Navidrome's native API sorts
/// songs by `playDate` and returns it, which is what makes a real "recently played" list
/// and an all-time top-tracks list possible, covering **every** device and every play
/// including the ones imported from Plex.
///
/// Worth being precise about what is and is not here: Navidrome does keep a per-play
/// event log — a `scrobbles` table with a timestamp per play — but **neither API exposes
/// it**. So per-play analysis (time of day, streaks) still has to come from the app's own
/// history, while totals and last-played come from here and reach back through the whole
/// library.
///
/// A second auth scheme, unavoidably: this endpoint wants a JWT, not the salted-MD5 that
/// every Subsonic call uses.
actor NavidromeClient {
    struct Song: Decodable, Sendable, Identifiable {
        let id: String
        let title: String
        var album: String?
        var albumId: String?
        var artist: String?
        var artistId: String?
        var albumArtistId: String?
        var playCount: Int?
        var playDate: Date?
        var starred: Bool?
        var rating: Int?
        var duration: Double?
    }

    private var credentials: SubsonicClient.Credentials?
    private var token: String?
    private let session: URLSession
    private let decoder: JSONDecoder

    init() {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 10
        session = URLSession(configuration: configuration)

        decoder = JSONDecoder()
        // Navidrome returns RFC3339 with nanosecond precision, which the standard
        // strategies reject.
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            guard let date = ServerDate.parse(text) else {
                throw DecodingError.dataCorrupted(.init(
                    codingPath: decoder.codingPath,
                    debugDescription: "Unrecognised date: \(text)"
                ))
            }
            return date
        }
    }

    func configure(_ credentials: SubsonicClient.Credentials?) {
        self.credentials = credentials
        token = nil
    }

    /// Songs sorted by the field named, newest first. `playDate` gives recently played;
    /// `playCount` gives most played.
    func songs(sortedBy field: String, limit: Int = 25) async throws -> [Song] {
        try await request(
            path: "api/song",
            query: [
                "_sort": field,
                "_order": "DESC",
                "_start": "0",
                "_end": String(limit),
            ]
        )
    }

    /// Only tracks that have actually been played; the API happily returns never-played
    /// ones otherwise, which makes a "recently played" list mostly noise.
    func recentlyPlayed(limit: Int = 25) async throws -> [Song] {
        try await songs(sortedBy: "playDate", limit: limit)
            .filter { $0.playDate != nil && ($0.playCount ?? 0) > 0 }
    }

    func mostPlayed(limit: Int = 25) async throws -> [Song] {
        try await songs(sortedBy: "playCount", limit: limit)
            .filter { ($0.playCount ?? 0) > 0 }
    }

    // MARK: - Plumbing

    private func login() async throws -> String {
        guard let credentials else { throw SubsonicClient.ClientError.notConfigured }

        var request = URLRequest(
            url: credentials.baseURL.appendingPathComponent("auth/login")
        )
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "username": credentials.username,
            "password": credentials.password,
        ])

        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = object["token"] as? String
        else {
            throw SubsonicClient.ClientError.server("Navidrome rejected the login.")
        }

        self.token = token
        return token
    }

    private func request<T: Decodable>(path: String, query: [String: String]) async throws -> T {
        guard let credentials else { throw SubsonicClient.ClientError.notConfigured }

        // One retry after a fresh login: the JWT expires, and the only way to find out is
        // to be told 401.
        for attempt in 0..<2 {
            let bearer = try await (token ?? login())

            var components = URLComponents(
                url: credentials.baseURL.appendingPathComponent(path),
                resolvingAgainstBaseURL: false
            )
            components?.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
            guard let url = components?.url else {
                throw SubsonicClient.ClientError.notConfigured
            }

            var request = URLRequest(url: url)
            request.setValue("Bearer \(bearer)", forHTTPHeaderField: "x-nd-authorization")

            let (data, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0

            if status == 401, attempt == 0 {
                token = nil
                continue
            }

            guard status == 200 else {
                throw SubsonicClient.ClientError.server("Navidrome replied \(status).")
            }
            return try decoder.decode(T.self, from: data)
        }

        throw SubsonicClient.ClientError.server("Navidrome would not authenticate.")
    }
}
