import Accelerate
import Foundation
import Observation

/// Turns the sample ring into a handful of band magnitudes, on the main actor.
///
/// The FFT deliberately runs *here* rather than in the audio callback. The callback's
/// only job is a `memcpy`; anything more on a real-time thread risks dropouts. Doing
/// the transform on a display-rate timer instead costs nothing audible and means the
/// maths can allocate, log and be reasoned about normally.
@MainActor
@Observable
final class SpectrumAnalyser {
    /// Bars on screen. 24 reads as a spectrum on a phone; 64 turns into a smear at
/// this width, and 12 looks like a level meter.
    static let bandCount = 24

    /// Normalised 0...1 per band, already smoothed. What the view draws.
    private(set) var bands = [Float](repeating: 0, count: bandCount)
    /// True when audio is genuinely arriving, so the view can say "no signal" rather
    /// than implying silence.
    private(set) var isLive = false

    private let buffer: AudioSampleBuffer
    private let size = AudioSampleBuffer.capacity
    private let half: Int

    private var samples: [Float]
    private var window: [Float]
    private var windowed: [Float]
    private var magnitudes: [Float]

    /// Separately allocated rather than being properties passed as `inout`, which is
    /// what keeps `DSPSplitComplex` from tripping Swift's exclusivity checks.
    private let realp: UnsafeMutablePointer<Float>
    private let imagp: UnsafeMutablePointer<Float>
    private let fftSetup: FFTSetup?
    private let log2n: vDSP_Length

    /// Band edges in bin space, spaced logarithmically: linear bins put three quarters
    /// of the bars above 5 kHz, where there is nothing to see.
    private let bandRanges: [Range<Int>]

    private var ticker: Task<Void, Never>?

    init(buffer: AudioSampleBuffer) {
        self.buffer = buffer
        half = size / 2
        log2n = vDSP_Length(log2(Double(size)).rounded())

        samples = [Float](repeating: 0, count: size)
        windowed = [Float](repeating: 0, count: size)
        magnitudes = [Float](repeating: 0, count: size / 2)

        // Hann, to stop the ring's arbitrary cut points ringing across every band.
        window = [Float](repeating: 0, count: size)
        vDSP_hann_window(&window, vDSP_Length(size), Int32(vDSP_HANN_NORM))

        realp = .allocate(capacity: size / 2)
        imagp = .allocate(capacity: size / 2)
        realp.initialize(repeating: 0, count: size / 2)
        imagp.initialize(repeating: 0, count: size / 2)

        fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))

        // 40 Hz to ~16 kHz. Below 40 is mostly rumble and above 16 k there is little
        // in a 44.1 kHz source worth a whole bar.
        let nyquist = 22050.0
        let lowest = 40.0
        let highest = 16000.0
        var ranges: [Range<Int>] = []
        for index in 0..<Self.bandCount {
            let lowFraction = Double(index) / Double(Self.bandCount)
            let highFraction = Double(index + 1) / Double(Self.bandCount)
            let lowHz = lowest * pow(highest / lowest, lowFraction)
            let highHz = lowest * pow(highest / lowest, highFraction)
            let lowBin = max(1, Int(lowHz / nyquist * Double(size / 2)))
            let highBin = min(size / 2, max(lowBin + 1, Int(highHz / nyquist * Double(size / 2))))
            ranges.append(lowBin..<highBin)
        }
        bandRanges = ranges
    }

    deinit {
        if let fftSetup { vDSP_destroy_fftsetup(fftSetup) }
        realp.deallocate()
        imagp.deallocate()
    }

    /// Starts sampling at display rate. Only while a visualiser is actually on screen —
    /// an FFT nobody is looking at is pure battery.
    func start() {
        guard ticker == nil else { return }
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(33))
                guard let self, !Task.isCancelled else { return }
                step()
            }
        }
    }

    func stop() {
        ticker?.cancel()
        ticker = nil
        // Fall to flat rather than freezing mid-bar.
        bands = [Float](repeating: 0, count: Self.bandCount)
        isLive = false
    }

    private func step() {
        guard let fftSetup else { return }

        isLive = buffer.isReceiving
        buffer.snapshot(into: &samples)

        vDSP_vmul(samples, 1, window, 1, &windowed, 1, vDSP_Length(size))

        var split = DSPSplitComplex(realp: realp, imagp: imagp)
        windowed.withUnsafeBufferPointer { pointer in
            pointer.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) { typed in
                vDSP_ctoz(typed, 2, &split, 1, vDSP_Length(half))
            }
        }

        vDSP_fft_zrip(fftSetup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
        vDSP_zvabs(&split, 1, &magnitudes, 1, vDSP_Length(half))

        var next = [Float](repeating: 0, count: Self.bandCount)
        for (index, range) in bandRanges.enumerated() {
            // Peak rather than mean across the band: an average washes out a narrow
            // strong tone, which is exactly the thing the eye wants to catch.
            var peak: Float = 0
            for bin in range where magnitudes[bin] > peak { peak = magnitudes[bin] }

            // Decibels, because linear magnitude puts everything in the bottom 5% of
            // the bar and music looks dead.
            let decibels = 20 * log10(max(peak, 1e-7) / Float(size))
            let normalised = (decibels + 78) / 78
            next[index] = min(max(normalised, 0), 1)
        }

        // Asymmetric smoothing: attack fast so a snare registers, release slowly so the
        // bars fall like a real meter instead of flickering.
        for index in next.indices {
            let current = bands[index]
            let target = next[index]
            bands[index] = target > current
                ? current + (target - current) * 0.6
                : current + (target - current) * 0.16
        }
    }
}
