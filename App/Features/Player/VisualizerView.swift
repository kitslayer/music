import SwiftUI

/// Three visualiser styles over the same 24 bands, cycled by tapping.
///
/// All of them are driven by the real spectrum — no timer-driven fakery — so a quiet
/// passage genuinely looks quiet. When nothing is arriving it says so rather than
/// animating anyway, which is the difference between a meter and a screensaver.
struct VisualizerView: View {
    @Environment(SpectrumAnalyser.self) private var analyser
    @Environment(AppState.self) private var appState

    @AppStorage("visualizer.style") private var rawStyle = Style.bars.rawValue

    enum Style: String, CaseIterable {
        case bars, mirror, ring

        var next: Style {
            let all = Style.allCases
            let index = all.firstIndex(of: self) ?? 0
            return all[(index + 1) % all.count]
        }

        var label: String {
            switch self {
            case .bars: return "Bars"
            case .mirror: return "Mirror"
            case .ring: return "Ring"
            }
        }
    }

    private var style: Style { Style(rawValue: rawStyle) ?? .bars }
    private var bands: [Float] { analyser.bands }

    var body: some View {
        ZStack {
            switch style {
            case .bars: bars
            case .mirror: mirror
            case .ring: ring
            }

            if !analyser.isLive {
                Text("No audio signal")
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.45))
            }
        }
        .padding(.horizontal, 20)
        .contentShape(Rectangle())
        .onTapGesture { rawStyle = style.next.rawValue }
        .overlay(alignment: .topTrailing) {
            Text(style.label)
                .font(.caption2.weight(.medium))
                .foregroundStyle(.white.opacity(0.4))
                .padding(.trailing, 4)
        }
        // The analyser only runs while this is on screen; an FFT nobody is watching is
        // pure battery drain.
        .onAppear {
            appState.player.startSpectrum()
            analyser.start()
        }
        .onDisappear {
            analyser.stop()
            appState.player.stopSpectrum()
        }
    }

    /// Colour rises with the band, so the top of a bar reads as intensity rather than
    /// needing a numeric scale.
    private func colour(for value: Float) -> Color {
        Color(
            hue: 0.98 - Double(min(value, 1)) * 0.12,
            saturation: 0.85,
            brightness: 0.55 + Double(min(value, 1)) * 0.45
        )
    }

    private var bars: some View {
        GeometryReader { geometry in
            let spacing: CGFloat = 3
            let width = max(
                2,
                (geometry.size.width - spacing * CGFloat(bands.count - 1)) / CGFloat(bands.count)
            )

            HStack(alignment: .bottom, spacing: spacing) {
                ForEach(Array(bands.enumerated()), id: \.offset) { _, value in
                    // A floor of 2pt so the row still reads as a spectrum at silence
                    // instead of vanishing.
                    Capsule()
                        .fill(colour(for: value))
                        .frame(
                            width: width,
                            height: max(2, CGFloat(value) * geometry.size.height)
                        )
                }
            }
            .frame(height: geometry.size.height, alignment: .bottom)
        }
    }

    private var mirror: some View {
        GeometryReader { geometry in
            let spacing: CGFloat = 3
            let width = max(
                2,
                (geometry.size.width - spacing * CGFloat(bands.count - 1)) / CGFloat(bands.count)
            )
            let half = geometry.size.height / 2

            HStack(alignment: .center, spacing: spacing) {
                ForEach(Array(bands.enumerated()), id: \.offset) { _, value in
                    Capsule()
                        .fill(colour(for: value))
                        .frame(width: width, height: max(2, CGFloat(value) * half * 1.9))
                }
            }
            .frame(height: geometry.size.height, alignment: .center)
        }
    }

    /// Bands as spokes. Starts at the top and goes clockwise, mirrored, so bass sits at
    /// the top on both sides and the shape stays symmetric.
    private var ring: some View {
        GeometryReader { geometry in
            let side = min(geometry.size.width, geometry.size.height)
            let centre = CGPoint(x: geometry.size.width / 2, y: geometry.size.height / 2)
            let inner = side * 0.17
            let maximum = side * 0.30

            ZStack {
                Circle()
                    .stroke(.white.opacity(0.12), lineWidth: 1)
                    .frame(width: inner * 2, height: inner * 2)

                ForEach(Array(bands.enumerated()), id: \.offset) { index, value in
                    let count = Double(bands.count)
                    let step = 180.0 / count
                    let angle = -90.0 + Double(index) * step + step / 2

                    ForEach([angle, -180 - angle], id: \.self) { rotation in
                        Capsule()
                            .fill(colour(for: value))
                            .frame(width: 4, height: max(3, CGFloat(value) * maximum))
                            .offset(y: -(inner + max(3, CGFloat(value) * maximum) / 2))
                            .rotationEffect(.degrees(rotation + 90))
                    }
                }
            }
            .position(centre)
        }
    }
}
