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

struct Album: Decodable, Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let artist: String?
    let artistId: String?
    let coverArt: String?
    let songCount: Int?
    let duration: Int?
    let year: Int?
    let starred: String?

    var isFavorite: Bool { starred != nil }
}

struct Song: Decodable, Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let album: String?
    let albumId: String?
    let artist: String?
    let artistId: String?
    let coverArt: String?
    let duration: Int?
    let track: Int?
    let discNumber: Int?
    let starred: String?
    let suffix: String?

    var isFavorite: Bool { starred != nil }
}

struct AlbumList2: Decodable, PayloadKeyed, Sendable {
    let album: [Album]?

    static var payloadKey: String { "albumList2" }
}

struct AlbumDetail: Decodable, PayloadKeyed, Identifiable, Sendable {
    let id: String
    let name: String
    let artist: String?
    let coverArt: String?
    let songCount: Int?
    let duration: Int?
    let year: Int?
    let song: [Song]?

    static var payloadKey: String { "album" }

    var songs: [Song] { song ?? [] }
}

extension Int {
    /// Seconds as `m:ss`, the only duration format the UI needs.
    var asDuration: String {
        let minutes = self / 60
        let seconds = self % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}
