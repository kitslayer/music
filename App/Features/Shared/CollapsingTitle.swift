import SwiftUI

/// Fades a title into the navigation bar as the header scrolls away.
///
/// `onScrollGeometryChange` fires at display rate, so the opacity is quantised and
/// only assigned when it actually changes -- otherwise the whole detail view
/// re-renders on every frame of a scroll.
struct CollapsingTitleModifier: ViewModifier {
    let title: String
    var threshold: CGFloat = 140
    var distance: CGFloat = 40

    @State private var opacity: Double = 0

    func body(content: Content) -> some View {
        content
            .navigationTitle("")
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text(title)
                        .font(.headline)
                        .lineLimit(1)
                        .opacity(opacity)
                }
            }
            .onScrollGeometryChange(for: CGFloat.self) { geometry in
                geometry.contentOffset.y
            } action: { _, offset in
                let raw = min(max((offset - threshold) / distance, 0), 1)
                let quantised = (raw * 20).rounded() / 20
                if quantised != opacity { opacity = quantised }
            }
    }
}

extension View {
    func collapsingTitle(_ title: String) -> some View {
        modifier(CollapsingTitleModifier(title: title))
    }
}

/// The Play / Shuffle pair used on every detail header.
struct PlayShuffleButtons: View {
    let onPlay: () -> Void
    let onShuffle: () -> Void
    /// Set while the track list is still being gathered, so a slow artist page shows
    /// progress instead of appearing to have ignored the tap.
    var isBusy = false

    var body: some View {
        HStack(spacing: Metrics.itemSpacing) {
            Button(action: onPlay) {
                Label("Play", systemImage: "play.fill")
                    .frame(maxWidth: .infinity)
            }
            Button(action: onShuffle) {
                Label("Shuffle", systemImage: "shuffle")
                    .frame(maxWidth: .infinity)
            }
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .disabled(isBusy)
        .overlay {
            if isBusy {
                ProgressView()
                    .tint(.white)
            }
        }
    }
}
