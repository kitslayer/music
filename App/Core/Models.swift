import Foundation

/// `getAlbumList2` sort orders. Only the ones the UI offers are listed.
enum AlbumSort: String, CaseIterable, Identifiable, Sendable {
    case recent
    case newest
    case frequent
    case alphabeticalByName
    case random

    var id: String { rawValue }

    var title: String {
        switch self {
        case .recent: return "Recently Played"
        case .newest: return "Recently Added"
        case .frequent: return "Most Played"
        case .alphabeticalByName: return "A–Z"
        case .random: return "Random"
        }
    }
}

// MARK: - Library items

/// The key a Subsonic response nests its payload under, so the envelope decoder can
/// reach through one generic layer instead of every model spelling out a wrapper.
protocol PayloadKeyed {
    static var payloadKey: String { get }
}

struct Album: Codable, Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    var artist: String?
    var artistId: String?
    var coverArt: String?
    var songCount: Int?
    var duration: Int?
    var year: Int?
    var genre: String?
    var starred: String?

    var isFavorite: Bool { starred != nil }
}

struct Song: Codable, Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    var album: String?
    var albumId: String?
    var artist: String?
    var artistId: String?
    var coverArt: String?
    var duration: Int?
    var track: Int?
    var discNumber: Int?
    var year: Int?
    var genre: String?
    var size: Int64?
    var suffix: String?
    var contentType: String?
    var bitRate: Int?
    /// Present on OpenSubsonic servers. Together these are what turns a bare "FLAC"
    /// badge into "FLAC 24/96", which is the readout that actually answers "is this
    /// lossless".
    var bitDepth: Int?
    var samplingRate: Int?
    var channelCount: Int?
    var starred: String?
    var userRating: Int?
    var playCount: Int?

    var isFavorite: Bool { starred != nil }

    /// Stable sort key that keeps multi-disc albums in playing order.
    var albumOrder: Int { (discNumber ?? 1) * 1000 + (track ?? 0) }
}

struct Artist: Codable, Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    var albumCount: Int?
    var coverArt: String?
    var artistImageUrl: String?
    var starred: String?
}

struct MusicFolder: Codable, Identifiable, Hashable, Sendable {
    let id: Int
    let name: String
}

struct Playlist: Codable, Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    var comment: String?
    var owner: String?
    var songCount: Int?
    var duration: Int?
    var coverArt: String?
    var changed: String?
}

struct Genre: Codable, Hashable, Sendable, Identifiable {
    let value: String
    var songCount: Int?
    var albumCount: Int?

    var id: String { value }
}

// MARK: - Lightweight navigation references
//
// Pushed onto NavigationStack instead of full models: cheap to hash, and a search
// result can navigate without first fetching a complete payload.

struct AlbumRef: Hashable, Sendable {
    let id: String
    let name: String
    var artist: String?
    var coverArt: String?

    init(id: String, name: String, artist: String? = nil, coverArt: String? = nil) {
        self.id = id
        self.name = name
        self.artist = artist
        self.coverArt = coverArt
    }

    init(_ album: Album) {
        self.init(id: album.id, name: album.name, artist: album.artist, coverArt: album.coverArt)
    }
}

struct ArtistRef: Hashable, Sendable {
    let id: String
    let name: String
    var coverArt: String?

    init(id: String, name: String, coverArt: String? = nil) {
        self.id = id
        self.name = name
        self.coverArt = coverArt
    }

    init(_ artist: Artist) {
        self.init(id: artist.id, name: artist.name, coverArt: artist.coverArt)
    }
}

struct PlaylistRef: Hashable, Sendable {
    let id: String
    let name: String
    var coverArt: String?

    init(id: String, name: String, coverArt: String? = nil) {
        self.id = id
        self.name = name
        self.coverArt = coverArt
    }

    init(_ playlist: Playlist) {
        self.init(id: playlist.id, name: playlist.name, coverArt: playlist.coverArt)
    }
}

// MARK: - Envelope payloads
//
// Every list field stays optional with a `?? []` accessor: Navidrome omits the key
// entirely rather than returning an empty array when there are no results.

struct MusicFolders: Decodable, PayloadKeyed, Sendable {
    let musicFolder: [MusicFolder]?
    static var payloadKey: String { "musicFolders" }
}

struct AlbumList2: Decodable, PayloadKeyed, Sendable {
    let album: [Album]?
    static var payloadKey: String { "albumList2" }
}

struct AlbumDetail: Codable, PayloadKeyed, Identifiable, Sendable {
    let id: String
    let name: String
    var artist: String?
    var artistId: String?
    var coverArt: String?
    var songCount: Int?
    var duration: Int?
    var year: Int?
    var genre: String?
    var starred: String?
    var song: [Song]?

    static var payloadKey: String { "album" }

    var songs: [Song] { (song ?? []).sorted { $0.albumOrder < $1.albumOrder } }
    var isFavorite: Bool { starred != nil }
    var hasMultipleDiscs: Bool { Set(songs.map { $0.discNumber ?? 1 }).count > 1 }
}

struct ArtistIndex: Codable, Hashable, Sendable, Identifiable {
    let name: String
    let artist: [Artist]?

    var id: String { name }
    var artists: [Artist] { artist ?? [] }
}

struct ArtistsRoot: Decodable, PayloadKeyed, Sendable {
    let index: [ArtistIndex]?
    static var payloadKey: String { "artists" }
}

struct ArtistDetail: Codable, PayloadKeyed, Identifiable, Sendable {
    let id: String
    let name: String
    var coverArt: String?
    var artistImageUrl: String?
    var albumCount: Int?
    var starred: String?
    var album: [Album]?

    static var payloadKey: String { "artist" }

    /// Newest first: for an artist you almost always want the latest release.
    var albums: [Album] { (album ?? []).sorted { ($0.year ?? 0) > ($1.year ?? 0) } }
    var isFavorite: Bool { starred != nil }
}

struct TopSongs: Decodable, PayloadKeyed, Sendable {
    let song: [Song]?
    static var payloadKey: String { "topSongs" }
}

struct Playlists: Decodable, PayloadKeyed, Sendable {
    let playlist: [Playlist]?
    static var payloadKey: String { "playlists" }
}

struct PlaylistDetail: Codable, PayloadKeyed, Identifiable, Sendable {
    let id: String
    let name: String
    var comment: String?
    var owner: String?
    var songCount: Int?
    var duration: Int?
    var coverArt: String?
    var entry: [Song]?

    static var payloadKey: String { "playlist" }

    /// Playlist order is the server's order -- never re-sorted.
    var songs: [Song] { entry ?? [] }
}

struct Genres: Decodable, PayloadKeyed, Sendable {
    let genre: [Genre]?
    static var payloadKey: String { "genres" }
}

struct SongsByGenre: Decodable, PayloadKeyed, Sendable {
    let song: [Song]?
    static var payloadKey: String { "songsByGenre" }
}

struct Starred2: Codable, PayloadKeyed, Sendable {
    var song: [Song]?
    var album: [Album]?
    var artist: [Artist]?

    static var payloadKey: String { "starred2" }

    var songs: [Song] { song ?? [] }
    var albums: [Album] { album ?? [] }
    var artists: [Artist] { artist ?? [] }
}

struct RandomSongs: Decodable, PayloadKeyed, Sendable {
    let song: [Song]?
    static var payloadKey: String { "randomSongs" }
}

struct SearchResult3: Codable, PayloadKeyed, Sendable {
    var artist: [Artist]?
    var album: [Album]?
    var song: [Song]?

    static var payloadKey: String { "searchResult3" }

    var artists: [Artist] { artist ?? [] }
    var albums: [Album] { album ?? [] }
    var songs: [Song] { song ?? [] }
    var isEmpty: Bool { artists.isEmpty && albums.isEmpty && songs.isEmpty }
}

// MARK: - Lyrics

struct LyricsList: Decodable, PayloadKeyed, Sendable {
    let structuredLyrics: [StructuredLyrics]?
    static var payloadKey: String { "lyricsList" }
}

/// Decoded tolerantly on purpose: the songLyrics v2 extension may add word-level
/// timing fields, and unknown keys must not break decoding. Encodable too, because
/// lyrics are cached to disk alongside downloaded audio.
struct StructuredLyrics: Codable, Hashable, Sendable {
    var displayArtist: String?
    var displayTitle: String?
    var lang: String?
    /// Milliseconds, applied to every line in this set.
    var offset: Int?
    var synced: Bool
    var line: [LyricLine]?

    var lines: [LyricLine] { line ?? [] }
}

/// The server's copy of the play queue, shared by every client on this account.
struct SavedQueue: Codable, PayloadKeyed, Sendable {
    var entry: [Song]?
    /// Song id of the track that was playing.
    var current: String?
    /// Milliseconds into `current`.
    var position: Int?
    /// ISO timestamp of the last save, used to decide whose queue is newer.
    var changed: String?
    /// The `c=` client name that saved it. Ours is skipped, so the app never adopts
    /// its own save back over a queue the user has since changed locally.
    var changedBy: String?

    static var payloadKey: String { "playQueue" }

    var songs: [Song] { entry ?? [] }

    var changedAt: Date? { ServerDate.parse(changed) }
}

/// Parses the timestamps Navidrome returns.
///
/// A shared static formatter would be simpler and is what I reached for first, but
/// `ISO8601DateFormatter` is a mutable class and not `Sendable`, so a `static let` of one
/// is a data race under strict concurrency. Building one per call is cheap next to the
/// network request that produced the string.
enum ServerDate {
    static func parse(_ value: String?) -> Date? {
        guard let value else { return nil }

        let plain = ISO8601DateFormatter()
        if let date = plain.date(from: value) { return date }

        // Navidrome includes fractional seconds, which the default options reject.
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: value)
    }
}

/// A track another client is playing right now. The song fields are inlined by the
/// server rather than nested, so this repeats them rather than embedding a `Song`.
struct NowPlayingEntry: Codable, Identifiable, Sendable {
    let id: String
    var title: String?
    var artist: String?
    var album: String?
    var coverArt: String?
    /// Which client, e.g. "Feishin" or "Music".
    var playerName: String?
    var username: String?
    /// Minutes since it started.
    var minutesAgo: Int?
}

struct NowPlayingList: Codable, PayloadKeyed, Sendable {
    var entry: [NowPlayingEntry]?
    static var payloadKey: String { "nowPlaying" }
}

struct ScanStatus: Codable, PayloadKeyed, Sendable {
    var scanning: Bool
    var count: Int?
    var folderCount: Int?
    var lastScan: String?
    var scanType: String?
    var elapsedTime: Int?

    static var payloadKey: String { "scanStatus" }

    var lastScanAt: Date? { ServerDate.parse(lastScan) }
}

struct CreatedPlaylist: Decodable, PayloadKeyed, Sendable {
    let playlist: Playlist
    static var payloadKey: String { "playlist" }

    /// The payload *is* the playlist, so the key is consumed by the envelope and this
    /// wrapper decodes from the same object rather than from a nested one.
    init(from decoder: Decoder) throws {
        playlist = try Playlist(from: decoder)
    }
}

struct SimilarSongs: Decodable, PayloadKeyed, Sendable {
    let song: [Song]?
    static var payloadKey: String { "similarSongs2" }
}

struct LyricLine: Codable, Hashable, Sendable {
    /// Milliseconds from the start of the track. Absent on unsynced lyrics.
    var start: Int?
    let value: String
}

// MARK: - Formatting

extension Int {
    /// Seconds as `m:ss`.
    var asDuration: String {
        let minutes = self / 60
        let seconds = self % 60
        return String(format: "%d:%02d", minutes, seconds)
    }

    /// Seconds as a human total, e.g. `1 hr 23 min` or `47 min`.
    var asLongDuration: String {
        let hours = self / 3600
        let minutes = (self % 3600) / 60
        if hours > 0 { return "\(hours) hr \(minutes) min" }
        return "\(minutes) min"
    }
}

extension Int64 {
    var asFileSize: String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: self)
    }
}
