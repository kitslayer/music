import Foundation
import Observation
import UIKit

/// Cover-art cache.
///
/// Replaces `AsyncImage`, which has no memory cache, cancels on scroll-away and
/// restarts on reappear -- a grey flicker field when scrolling a grid fast. The
/// crucial part is `cached(_:_:)` being **synchronous**: a view can check it during
/// `init` and, on a hit, render with no placeholder and no transition at all.
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

        guard let url = url(for: id, size: size) else { return nil }

        let task = Task<UIImage?, Never> { [session] in
            guard let (data, _) = try? await session.data(from: url) else { return nil }
            // Decoding is expensive; keep it off the main actor.
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
