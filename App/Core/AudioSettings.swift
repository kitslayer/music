import Foundation
import Observation

/// EQ and crossfade, and the one honest constraint attached to them.
///
/// Enabling this switches the sound path from `AVQueuePlayer` to `AVAudioEngine`,
/// which has no networking at all — so it applies **only when every track in the
/// preload window is a completed download**. Streaming silently keeps the default
/// path, because the alternative would be a setting that appears to do nothing on
/// half your library.
///
/// Gapless and crossfade are mutually exclusive by definition — one is zero overlap,
/// the other is deliberate overlap — so crossfade at 0 seconds means the engine
/// schedules tracks back-to-back on one node, which is exactly gapless.
@MainActor
@Observable
final class AudioSettings {
    /// Centre frequencies, one per band. Chosen to be recognisable rather than
    /// technically even: bass, low-mid, mid, presence, air.
    static let bandFrequencies: [Float] = [60, 250, 1000, 4000, 12000]
    static let bandNames = ["60", "250", "1k", "4k", "12k"]
    static let gainRange: ClosedRange<Float> = -12...12

    private enum Key {
        static let enabled = "audio.enhanced.enabled"
        static let gains = "audio.eq.gains"
        static let crossfade = "audio.crossfade.seconds"
        static let preset = "audio.eq.preset"
    }

    /// Off by default, deliberately. The default path is the one that handles
    /// streaming, stalls and interruptions correctly; this one trades that for effects.
    var isEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: Key.enabled)
            // Switching this changes which output serves the current track, so the
            // player has to re-decide immediately rather than at the next track.
            onChange?()
        }
    }

    /// Decibels per band, in `bandFrequencies` order.
    var gains: [Float] {
        didSet { UserDefaults.standard.set(gains, forKey: Key.gains) }
    }

    /// Seconds of overlap. 0 means gapless.
    var crossfadeSeconds: Double {
        didSet { UserDefaults.standard.set(crossfadeSeconds, forKey: Key.crossfade) }
    }


    var presetName: String {
        didSet { UserDefaults.standard.set(presetName, forKey: Key.preset) }
    }

    /// Fired when a value changes that the running engine has to pick up immediately.
    var onChange: (() -> Void)?

    init() {
        let defaults = UserDefaults.standard
        isEnabled = defaults.bool(forKey: Key.enabled)
        crossfadeSeconds = defaults.object(forKey: Key.crossfade) as? Double ?? 0
        presetName = defaults.string(forKey: Key.preset) ?? Preset.flat.name

        let stored = defaults.array(forKey: Key.gains) as? [Float] ?? []
        gains = stored.count == Self.bandFrequencies.count
            ? stored
            : Array(repeating: 0, count: Self.bandFrequencies.count)
    }

    var isFlat: Bool {
        gains.allSatisfy { abs($0) < 0.01 }
    }

    func apply(_ preset: Preset) {
        gains = preset.gains
        presetName = preset.name
        onChange?()
    }

    func setGain(_ value: Float, forBand index: Int) {
        guard gains.indices.contains(index) else { return }
        gains[index] = min(max(value, Self.gainRange.lowerBound), Self.gainRange.upperBound)
        // Any hand adjustment stops claiming to be a named preset.
        presetName = Preset.match(gains)?.name ?? Preset.custom
        onChange?()
    }

    struct Preset: Identifiable, Sendable {
        let name: String
        let gains: [Float]

        var id: String { name }

        static let custom = "Custom"

        static let flat = Preset(name: "Flat", gains: [0, 0, 0, 0, 0])
        static let all: [Preset] = [
            flat,
            Preset(name: "Bass Boost", gains: [6, 3, 0, 0, 0]),
            Preset(name: "Vocal", gains: [-2, 0, 3, 4, 1]),
            // A shallow smile rather than the usual +8 canyon: heavy-handed presets
            // clip on loud masters, and the engine has no limiter after the EQ.
            Preset(name: "Loudness", gains: [5, 1, -1, 2, 4]),
            Preset(name: "Warm", gains: [3, 2, 0, -1, -3]),
        ]

        static func match(_ gains: [Float]) -> Preset? {
            all.first { preset in
                zip(preset.gains, gains).allSatisfy { abs($0 - $1) < 0.01 }
            }
        }
    }
}
