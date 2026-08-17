import SwiftUI

/// Cover art. Probes the memory cache synchronously so a cached image renders on
/// the first frame with no placeholder flash; only a genuine miss fades in.
struct ArtworkImage: View {
    @Environment(ArtworkStore.self) private var store

    let id: String?
    var size: ArtworkStore.Size = .card
    var cornerRadius: CGFloat = Metrics.radiusCard

    @State private var image: UIImage?
    @State private var didLoad = false

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                placeholder
            }
        }
        .clipped()
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .task(id: id) { await load() }
    }

    private var placeholder: some View {
        Rectangle()
            .fill(.quaternary)
            .overlay {
                Image(systemName: "music.note")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
    }

    private func load() async {
        // Cache hit: assign with no animation so there is no visible transition.
        if let hit = store.cached(id, size) {
            image = hit
            didLoad = true
            return
        }

        image = nil
        didLoad = false

        let loaded = await store.image(for: id, size: size)
        guard !Task.isCancelled else { return }

        withAnimation(.easeOut(duration: 0.15)) {
            image = loaded
        }
        didLoad = true
    }
}

/// Circular variant for artists.
struct ArtistArtwork: View {
    @Environment(ArtworkStore.self) private var store

    let id: String?
    var diameter: CGFloat
    var initials: String?

    @State private var image: UIImage?

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Circle()
                    .fill(.quaternary)
                    .overlay {
                        // Navidrome without a Last.fm key returns no artist image,
                        // so a monogram is the common case rather than the fallback.
                        Text(initials ?? "?")
                            .font(.system(size: diameter * 0.36, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
            }
        }
        .frame(width: diameter, height: diameter)
        .clipShape(Circle())
        .task(id: id) {
            if let hit = store.cached(id, .thumb) {
                image = hit
                return
            }
            image = nil
            let loaded = await store.image(for: id, size: .thumb)
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.15)) { image = loaded }
        }
    }
}

extension String {
    /// "Red Hot Chili Peppers" -> "RH"
    var monogram: String {
        let words = split(separator: " ").prefix(2)
        return words.compactMap { $0.first }.map(String.init).joined().uppercased()
    }
}
