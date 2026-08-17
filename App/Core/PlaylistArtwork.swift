import Observation
import UIKit

/// Custom playlist covers, stored on this device.
///
/// **Device-local by necessity, not by choice.** The Subsonic API has no endpoint for
/// setting playlist artwork — `updatePlaylist` takes a name, a comment, a public flag and
/// track changes, and nothing else. Navidrome derives a playlist's cover from its tracks.
/// So a chosen image cannot reach the server, and will not appear in desktop Feishin.
/// That is stated in the UI rather than left to be discovered.
///
/// Stored beside the offline artwork so it survives the same way, and re-encoded to a
/// sensible size: a modern phone photo is 4 MB of 4032×3024, which is absurd for a 56pt
/// row and would be held in memory at full resolution.
@MainActor
@Observable
final class PlaylistArtwork {
    /// Bumped when an image changes, so views observing this re-read the file. The images
    /// themselves are not held here — `ArtworkStore`'s memory cache does that.
    private(set) var generation = 0

    private let side: CGFloat = 1024

    func image(for playlistID: String) -> UIImage? {
        UIImage(contentsOfFile: url(for: playlistID).path)
    }

    func hasCustomImage(for playlistID: String) -> Bool {
        FileManager.default.fileExists(atPath: url(for: playlistID).path)
    }

    /// Accepts raw picked data, which may be HEIC, enormous, or rotated by EXIF.
    func setImage(data: Data, for playlistID: String) {
        guard let source = UIImage(data: data) else { return }
        setImage(source, for: playlistID)
    }

    func setImage(_ source: UIImage, for playlistID: String) {
        guard let square = squared(source),
              let data = square.jpegData(compressionQuality: 0.85)
        else { return }

        try? data.write(to: url(for: playlistID), options: .atomic)
        generation += 1
    }

    func removeImage(for playlistID: String) {
        try? FileManager.default.removeItem(at: url(for: playlistID))
        generation += 1
    }

    /// Centre-cropped to a square and scaled down. Covers are shown square everywhere in
    /// the app, so cropping once here beats every call site fighting the aspect ratio.
    private func squared(_ source: UIImage) -> UIImage? {
        let shortest = min(source.size.width, source.size.height)
        let crop = CGRect(
            x: (source.size.width - shortest) / 2,
            y: (source.size.height - shortest) / 2,
            width: shortest,
            height: shortest
        )

        // Redrawing rather than using `cgImage(cropping:)` so EXIF rotation is applied
        // instead of being carried along and rendered sideways.
        let target = min(shortest, side)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true

        return UIGraphicsImageRenderer(
            size: CGSize(width: target, height: target),
            format: format
        ).image { _ in
            source.draw(in: CGRect(
                x: -crop.origin.x * target / shortest,
                y: -crop.origin.y * target / shortest,
                width: source.size.width * target / shortest,
                height: source.size.height * target / shortest
            ))
        }
    }

    private func url(for playlistID: String) -> URL {
        let safe = playlistID.replacingOccurrences(of: "/", with: "_")
        return Paths.artwork.appendingPathComponent("playlist-\(safe).jpg")
    }
}
