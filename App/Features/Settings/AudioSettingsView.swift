import SwiftUI

/// Its own screen rather than a block in Settings: five sliders and a preset list is
/// too much to sit under the server address, and the constraint needs room to be
/// explained rather than buried.
struct AudioSettingsView: View {
    @Environment(AudioSettings.self) private var audio
    @Environment(DownloadCenter.self) private var downloads

    var body: some View {
        Form {
            Section {
                Toggle("EQ and Crossfade", isOn: Binding(
                    get: { audio.isEnabled },
                    set: { audio.isEnabled = $0 }
                ))
            } footer: {
                // Said plainly and once. This is a real limitation of the audio
                // framework, not a preference, and a user who does not know it will
                // reasonably think the feature is broken.
                Text("""
                Applies to downloaded tracks only. Streaming keeps the standard \
                gapless player, which is the only one that can buffer over the \
                network. \(downloadedSummary)
                """)
            }

            if audio.isEnabled {
                Section {
                    ForEach(Array(AudioSettings.bandFrequencies.indices), id: \.self) { index in
                        bandSlider(index)
                    }

                    Button("Reset to Flat") {
                        audio.apply(.flat)
                    }
                    .disabled(audio.isFlat)
                } header: {
                    HStack {
                        Text("Equaliser")
                        Spacer()
                        Text(audio.presetName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textCase(nil)
                    }
                }

                Section("Presets") {
                    ForEach(AudioSettings.Preset.all) { preset in
                        Button {
                            audio.apply(preset)
                        } label: {
                            HStack {
                                Text(preset.name)
                                    .foregroundStyle(.primary)
                                Spacer()
                                if audio.presetName == preset.name {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(Color.appTint)
                                }
                            }
                        }
                    }
                }

                Section {
                    Slider(
                        value: Binding(
                            get: { audio.crossfadeSeconds },
                            set: { audio.crossfadeSeconds = $0 }
                        ),
                        in: 0...12,
                        step: 1
                    ) {
                        Text("Crossfade")
                    } minimumValueLabel: {
                        Text("Off")
                            .font(.caption2)
                    } maximumValueLabel: {
                        Text("12s")
                            .font(.caption2)
                    }

                    LabeledContent("Crossfade", value: crossfadeLabel)
                } header: {
                    Text("Crossfade")
                } footer: {
                    Text("""
                    Off means gapless — the next track starts the instant the last \
                    sample ends, which is what you want for an album. Anything above \
                    zero overlaps them instead, so the two cannot both apply to the \
                    same transition.
                    """)
                }
            }
        }
        .navigationTitle("Audio")
    }

    private func bandSlider(_ index: Int) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text("\(AudioSettings.bandNames[index]) Hz")
                    .font(.footnote.monospacedDigit())
                Spacer()
                Text(gainLabel(audio.gains[index]))
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(
                        abs(audio.gains[index]) < 0.01 ? .secondary : Color.appTint
                    )
            }

            Slider(
                value: Binding(
                    get: { Double(audio.gains[index]) },
                    set: { audio.setGain(Float($0), forBand: index) }
                ),
                in: Double(AudioSettings.gainRange.lowerBound)
                    ...Double(AudioSettings.gainRange.upperBound),
                step: 0.5
            )
        }
    }

    private func gainLabel(_ gain: Float) -> String {
        gain > 0 ? "+\(String(format: "%.1f", gain)) dB" : "\(String(format: "%.1f", gain)) dB"
    }

    private var crossfadeLabel: String {
        let seconds = Int(audio.crossfadeSeconds)
        return seconds == 0 ? "Off (gapless)" : "\(seconds) seconds"
    }

    private var downloadedSummary: String {
        let count = downloads.catalog.entries.count
        return count == 0
            ? "Nothing is downloaded yet."
            : "\(count) tracks are downloaded."
    }
}
