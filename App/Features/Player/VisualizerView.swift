import SwiftUI

/// Three visualiser styles, drawn in a `Canvas`.
///
/// A `Canvas` rather than a stack of `Shape` views: thirty-two views being diffed and
/// re-laid-out sixty times a second is a lot of work for something that is one drawing,
/// and it rules out the gradients, glow and blending that are most of what makes this
/// look like part of the app rather than a debug readout.
///
/// Colour comes from the album art, like everything else on this screen. A fixed pink
/// ramp was the main reason it looked bolted on: the backdrop behind it is the sleeve,
/// and the bars in front were ignoring it.
struct VisualizerView: View {
    @Environment(SpectrumAnalyser.self) private var analyser
    @Environment(AppState.self) private var appState
    @Environment(ArtworkStore.self) private var artwork

    @AppStorage("visualizer.style") private var rawStyle = Style.bars.rawValue

    /// Shown briefly after a change, then fades — the name is useful the moment you tap
    /// and clutter thereafter.
    @State private var labelShownAt: Date?

    enum Style: String, CaseIterable {
        case bars, wave, ring

        var next: Style {
            let all = Style.allCases
            return all[((all.firstIndex(of: self) ?? 0) + 1) % all.count]
        }

        var label: String {
            switch self {
            case .bars: return "Bars"
            case .wave: return "Wave"
            case .ring: return "Ring"
            }
        }
    }

    private var style: Style { Style(rawValue: rawStyle) ?? .bars }

    var body: some View {
        // Redrawn on the display's own schedule rather than whenever the analyser
        // happens to publish, so motion is smooth even though the data arrives at 30 Hz.
        TimelineView(.animation) { _ in
            Canvas(opaque: false) { context, size in
                let bands = analyser.bands
                let peaks = analyser.peaks
                guard !bands.isEmpty else { return }

                switch style {
                case .bars: drawBars(context: context, size: size, bands: bands, peaks: peaks)
                case .wave: drawWave(context: context, size: size, bands: bands)
                case .ring: drawRing(context: context, size: size, bands: bands, peaks: peaks)
                }
            }
        }
        .padding(.horizontal, 18)
        .contentShape(Rectangle())
        .onTapGesture {
            rawStyle = style.next.rawValue
            labelShownAt = .now
        }
        .overlay(alignment: .top) { styleLabel }
        .onAppear {
            appState.player.startSpectrum()
            analyser.start()
        }
        .onDisappear { analyser.stop() }
    }

    @ViewBuilder
    private var styleLabel: some View {
        if let shownAt = labelShownAt {
            Text(style.label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white.opacity(0.75))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(.ultraThinMaterial, in: Capsule())
                .task(id: shownAt) {
                    try? await Task.sleep(for: .seconds(1.4))
                    withAnimation(.easeOut(duration: 0.4)) { labelShownAt = nil }
                }
                .transition(.opacity)
        }
    }

    // MARK: - Colour

    private var colours: (base: Color, highlight: Color) {
        guard let palette = artwork.palette(for: appState.player.currentSong?.coverArt) else {
            return (Color.appTint, Color.appTint.opacity(0.65))
        }
        return (Color(palette.base), Color(palette.highlight))
    }

    /// Bright at the top, deep at the bottom, so a tall bar reads as intensity rather
    /// than just length.
    private func gradient(in rect: CGRect) -> GraphicsContext.Shading {
        let (base, highlight) = colours
        return .linearGradient(
            Gradient(colors: [highlight, base]),
            startPoint: CGPoint(x: rect.midX, y: rect.minY),
            endPoint: CGPoint(x: rect.midX, y: rect.maxY)
        )
    }

    // MARK: - Bars

    private func drawBars(
        context: GraphicsContext,
        size: CGSize,
        bands: [Float],
        peaks: [Float]
    ) {
        let count = bands.count
        let spacing: CGFloat = 3
        let width = max(2, (size.width - spacing * CGFloat(count - 1)) / CGFloat(count))

        // The reflection takes the bottom third, so the bars themselves get the rest.
        let baseline = size.height * 0.72
        let maximum = baseline - 4

        // Drawn once into a blurred layer underneath, which is what gives the light a
        // source instead of the bars looking like stickers.
        context.drawLayer { glow in
            glow.addFilter(.blur(radius: 12))
            glow.opacity = 0.55
            for (index, value) in bands.enumerated() {
                let rect = barRect(index: index, value: value, width: width,
                                   spacing: spacing, baseline: baseline, maximum: maximum)
                glow.fill(Path(roundedRect: rect, cornerRadius: width / 2), with: gradient(in: rect))
            }
        }

        for (index, value) in bands.enumerated() {
            let rect = barRect(index: index, value: value, width: width,
                               spacing: spacing, baseline: baseline, maximum: maximum)
            context.fill(Path(roundedRect: rect, cornerRadius: width / 2), with: gradient(in: rect))

            // Peak cap: hangs where the bar last reached, then sinks.
            let peak = CGFloat(peaks[index])
            if peak > 0.02 {
                let capY = baseline - peak * maximum
                let cap = CGRect(x: rect.minX, y: capY - 2, width: width, height: 2.5)
                context.fill(
                    Path(roundedRect: cap, cornerRadius: 1.25),
                    with: .color(.white.opacity(0.85))
                )
            }
        }

        // A short, fading mirror below the baseline reads as the bars standing on a
        // surface, which is most of the sense of depth here.
        context.drawLayer { reflection in
            reflection.opacity = 0.22
            reflection.translateBy(x: 0, y: baseline * 2)
            reflection.scaleBy(x: 1, y: -1)
            reflection.clip(to: Path(CGRect(
                x: 0, y: baseline - size.height * 0.22, width: size.width, height: size.height * 0.22
            )))
            for (index, value) in bands.enumerated() {
                let rect = barRect(index: index, value: value, width: width,
                                   spacing: spacing, baseline: baseline, maximum: maximum)
                reflection.fill(
                    Path(roundedRect: rect, cornerRadius: width / 2),
                    with: gradient(in: rect)
                )
            }
        }
    }

    private func barRect(
        index: Int,
        value: Float,
        width: CGFloat,
        spacing: CGFloat,
        baseline: CGFloat,
        maximum: CGFloat
    ) -> CGRect {
        // A floor rather than zero: a row of dots at silence still reads as a spectrum
        // waiting, where nothing at all reads as broken.
        let height = max(width * 0.9, CGFloat(value) * maximum)
        return CGRect(
            x: CGFloat(index) * (width + spacing),
            y: baseline - height,
            width: width,
            height: height
        )
    }

    // MARK: - Wave

    /// One filled curve through the band tops, mirrored. Smooth where the bars are
    /// discrete, which suits sustained music far better.
    private func drawWave(context: GraphicsContext, size: CGSize, bands: [Float]) {
        let centre = size.height / 2
        let amplitude = size.height * 0.42
        let step = size.width / CGFloat(bands.count - 1)

        func curve(sign: CGFloat) -> Path {
            var path = Path()
            path.move(to: CGPoint(x: 0, y: centre))

            for index in bands.indices {
                let x = CGFloat(index) * step
                let y = centre - sign * CGFloat(bands[index]) * amplitude
                if index == 0 {
                    path.addLine(to: CGPoint(x: x, y: y))
                } else {
                    // Midpoint quadratics: a cheap smooth interpolation that never
                    // overshoots, unlike a naive cubic through every point.
                    let previousX = CGFloat(index - 1) * step
                    let previousY = centre - sign * CGFloat(bands[index - 1]) * amplitude
                    let midX = (previousX + x) / 2
                    path.addQuadCurve(
                        to: CGPoint(x: midX, y: (previousY + y) / 2),
                        control: CGPoint(x: previousX, y: previousY)
                    )
                    path.addQuadCurve(to: CGPoint(x: x, y: y), control: CGPoint(x: x, y: y))
                }
            }

            path.addLine(to: CGPoint(x: size.width, y: centre))
            path.closeSubpath()
            return path
        }

        let (base, highlight) = colours
        let shading = GraphicsContext.Shading.linearGradient(
            Gradient(colors: [highlight.opacity(0.95), base.opacity(0.25)]),
            startPoint: CGPoint(x: size.width / 2, y: centre - amplitude),
            endPoint: CGPoint(x: size.width / 2, y: centre + amplitude)
        )

        context.drawLayer { glow in
            glow.addFilter(.blur(radius: 16))
            glow.opacity = 0.6
            glow.fill(curve(sign: 1), with: shading)
            glow.fill(curve(sign: -1), with: shading)
        }

        context.fill(curve(sign: 1), with: shading)
        context.fill(curve(sign: -1), with: shading)

        context.stroke(
            curve(sign: 1), with: .color(.white.opacity(0.5)), lineWidth: 1.5
        )
        context.stroke(
            curve(sign: -1), with: .color(.white.opacity(0.28)), lineWidth: 1
        )
    }

    // MARK: - Ring

    /// Spokes radiating from a hollow centre, mirrored left to right so bass sits at the
    /// top on both sides and the shape stays symmetric however the music moves.
    private func drawRing(
        context: GraphicsContext,
        size: CGSize,
        bands: [Float],
        peaks: [Float]
    ) {
        let centre = CGPoint(x: size.width / 2, y: size.height / 2)
        let side = min(size.width, size.height)
        let inner = side * 0.19
        let maximum = side * 0.27
        let (base, highlight) = colours

        context.stroke(
            Path(ellipseIn: CGRect(
                x: centre.x - inner, y: centre.y - inner, width: inner * 2, height: inner * 2
            )),
            with: .color(.white.opacity(0.10)),
            lineWidth: 1
        )

        let spokeWidth = max(2, (.pi * inner) / CGFloat(bands.count) * 0.75)

        func spokes(into context: GraphicsContext) {
            var context = context
            for (index, value) in bands.enumerated() {
                let fraction = Double(index) / Double(bands.count)
                let length = max(3, CGFloat(value) * maximum)

                for direction in [1.0, -1.0] {
                    // Half a turn per side, starting at the top.
                    let angle = (-.pi / 2) + direction * fraction * .pi
                    let unit = CGPoint(x: cos(angle), y: sin(angle))

                    let start = CGPoint(
                        x: centre.x + unit.x * inner,
                        y: centre.y + unit.y * inner
                    )
                    let end = CGPoint(
                        x: centre.x + unit.x * (inner + length),
                        y: centre.y + unit.y * (inner + length)
                    )

                    var spoke = Path()
                    spoke.move(to: start)
                    spoke.addLine(to: end)
                    context.stroke(
                        spoke,
                        with: .linearGradient(
                            Gradient(colors: [base, highlight]),
                            startPoint: start,
                            endPoint: end
                        ),
                        style: StrokeStyle(lineWidth: spokeWidth, lineCap: .round)
                    )

                    let peak = CGFloat(peaks[index])
                    if peak > 0.05 {
                        let capCentre = CGPoint(
                            x: centre.x + unit.x * (inner + peak * maximum + 3),
                            y: centre.y + unit.y * (inner + peak * maximum + 3)
                        )
                        context.fill(
                            Path(ellipseIn: CGRect(
                                x: capCentre.x - 1.4, y: capCentre.y - 1.4, width: 2.8, height: 2.8
                            )),
                            with: .color(.white.opacity(0.8))
                        )
                    }
                }
            }
        }

        context.drawLayer { glow in
            glow.addFilter(.blur(radius: 14))
            glow.opacity = 0.6
            spokes(into: glow)
        }
        spokes(into: context)
    }
}
