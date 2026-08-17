import Foundation
import Observation
import UIKit

/// Cover-art cache.
///
/// Replaces `AsyncImage`, which has no memory cache, cancels on scroll-away and
/// restarts on reappear -- a grey flicker field when scrolling a grid fast. The
/// crucial part is `cached(_:_:)` being **synchronous**: a view can check it during
/// `init` and, on a hit, render with no placeholder and no transition at all.
///
/// Three layers, and the third is the reason this file changed: memory, then a
/// **permanent** copy in Application Support, then the network. `URLCache` alone was not
/// enough — iOS purges it under storage pressure, so a downloaded album could keep its
/// audio and lose its cover, which offline is unrecoverable. Anything downloaded gets
/// its art kept deliberately, next to the music.
@MainActor
@Observable
final class ArtworkStore {
    /// Three sizes only, so both this cache and the server's stay hot.
    enum Size: Int, Sendable {
        case thumb = 160
        case card = 512
        case full = 1200
    }

    private let memory = NSCache<NSString, UIImage>()
    private let session: URLSession
    private var inFlight: [String: Task<UIImage?, Never>] = [:]
    private var signer: SubsonicSigner?

    init() {
        memory.countLimit = 300
        memory.totalCostLimit = 64 * 1024 * 1024

        let configuration = URLSessionConfiguration.default
        configuration.urlCache = URLCache(
            memoryCapacity: 16 * 1024 * 1024,
            diskCapacity: 512 * 1024 * 1024,
            diskPath: "artwork"
        )
        configuration.requestCachePolicy = .returnCacheDataElseLoad
        configuration.timeoutIntervalForRequest = 12
        session = URLSession(configuration: configuration)
    }

    /// Where a size is kept on disk. Keyed by cover id, so the many tracks sharing an
    /// album cover store it once.
    private func fileURL(_ id: String, _ size: Size) -> URL {
        let safe = id.replacingOccurrences(of: "/", with: "_")
        return Paths.artwork.appendingPathComponent("\(safe)@\(size.rawValue).jpg")
    }

    /// Persists a size for offline use. Called when a track is downloaded.
    func persist(id: String?, size: Size) async {
        guard let id else { return }
        let destination = fileURL(id, size)
        guard !FileManager.default.fileExists(atPath: destination.path) else { return }

        guard let image = await image(for: id, size: size),
              let data = image.jpegData(compressionQuality: 0.85)
        else { return }

        try? data.write(to: destination, options: .atomic)
    }

    /// Every size a downloaded track needs: rows, grids and the player.
    func persistAll(id: String?) async {
        for size in [Size.thumb, .card, .full] {
            await persist(id: id, size: size)
        }
    }

    /// Bytes held for offline artwork, for the settings screen.
    static func diskUsage() -> Int64 {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: Paths.artwork,
            includingPropertiesForKeys: [.fileSizeKey]
        )) ?? []
        return contents.reduce(Int64(0)) { total, url in
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            return total + Int64(size)
        }
    }

    func configure(signer: SubsonicSigner?) {
        self.signer = signer
        if signer == nil {
            memory.removeAllObjects()
            inFlight.removeAll()
        }
    }

    private func key(_ id: String, _ size: Size) -> NSString {
        "\(id)@\(size.rawValue)" as NSString
    }

    /// Synchronous memory-cache probe. This is what removes the flicker.
    func cached(_ id: String?, _ size: Size) -> UIImage? {
        guard let id else { return nil }
        return memory.object(forKey: key(id, size))
    }

    func url(for id: String?, size: Size) -> URL? {
        guard let id, let signer else { return nil }
        return signer.url("getCoverArt.view", ["id": id, "size": String(size.rawValue)])
    }

    /// Loads and decodes off the main actor. Concurrent requests for the same key
    /// share one task, so scrolling a grid up and down does not issue duplicates.
    func image(for id: String?, size: Size) async -> UIImage? {
        guard let id else { return nil }

        if let hit = memory.object(forKey: key(id, size)) { return hit }

        let cacheKey = "\(id)@\(size.rawValue)"
        if let existing = inFlight[cacheKey] { return await existing.value }

        let file = fileURL(id, size)
        let remote = url(for: id, size: size)

        let task = Task<UIImage?, Never> { [session] in
            // Disk before network, so offline art appears and an online launch does not
            // re-fetch what is already kept. Decoding is expensive either way, so both
            // paths do it off the main actor.
            if let data = try? Data(contentsOf: file) {
                // Bound to a local first: a trailing closure inside an `if let`
                // condition cannot be parsed -- it reads as the `if` body.
                let decoded = await Task.detached(priority: .userInitiated) {
                    UIImage(data: data)
                }.value
                if let decoded { return decoded }
            }

            guard let remote,
                  let (data, _) = try? await session.data(from: remote)
            else { return nil }

            return await Task.detached(priority: .userInitiated) {
                UIImage(data: data)
            }.value
        }
        inFlight[cacheKey] = task

        let image = await task.value
        inFlight[cacheKey] = nil

        if let image {
            let cost = Int(image.size.width * image.size.height * 4)
            memory.setObject(image, forKey: key(id, size), cost: cost)
        }
        return image
    }
}
