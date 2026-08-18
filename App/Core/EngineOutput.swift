import AVFoundation
import Foundation

/// The enhanced output: five-band EQ and crossfade, via `AVAudioEngine`.
///
/// The hard constraint that shapes everything here: `AVAudioFile` reads **local files
/// only**. `AVAudioEngine` has no networking, no buffering, no stall handling and no
/// byte-range seeking. So this output refuses any window containing a track that is
/// not a completed download, and the controller falls back to `AVQueuePlayer` — which
/// is why downloads and effects are the same feature.
///
/// Graph: two player nodes into a mixer (a mixer, because it is the only node that
/// accepts inputs at different sample rates, and a 44.1 kHz MP3 following a 96 kHz
/// FLAC is normal in this library), then the EQ, then the main mixer.
///
/// ```
/// playerA ─┐
///          ├─ mixer ─ eq ─ mainMixer ─ output
/// playerB ─┘
/// ```
///
/// Two nodes rather than one because a crossfade needs both tracks audible at once.
/// With crossfade at zero the *same* node schedules them back to back, which is real
/// gapless — `AVAudioPlayerNode` renders consecutively scheduled files with no gap.
@MainActor
final class EngineOutput: AudioOutput {
    private(set) var elapsed: Double = 0
    private(set) var duration: Double = 0
    /// Always false: a local file cannot stall.
    let isBuffering = false

    var volume: Float {
        get { engine.mainMixerNode.outputVolume }
        set { engine.mainMixerNode.outputVolume = newValue }
    }

    var onAdvanced: ((String?) -> Void)?
    var onTick: ((Double, Bool) -> Void)?
    var locate: ((Song) -> MediaLocation?)?

    private let engine = AVAudioEngine()
    private let mixer = AVAudioMixerNode()
    private let eq = AVAudioUnitEQ(numberOfBands: AudioSettings.bandFrequencies.count)
    private let players = [AVAudioPlayerNode(), AVAudioPlayerNode()]

    private let settings: AudioSettings

    /// Which of the two player nodes is carrying the current track.
    private var activeIndex = 0
    private var activePlayer: AVAudioPlayerNode { players[activeIndex] }
    private var idlePlayer: AVAudioPlayerNode { players[1 - activeIndex] }

    /// The track on each node, so a completion callback can be attributed.
    private var songOnNode: [String?] = [nil, nil]
    private var window: [Song] = []
    /// Frame the current track was scheduled from, so `elapsed` survives a seek.
    private var startFrame: AVAudioFramePosition = 0
    private var sampleRate: Double = 44100
    /// The rate the fixed links in the graph are wired at. Tracked so a route change
    /// to hardware running at a different rate can be rewired rather than silently
    /// resampled twice.
    private var graphRate: Double = 0
    private var isRunning = false
    private var hasScheduledNext = false

    private var ticker: Task<Void, Never>?
    private var fadeTask: Task<Void, Never>?
    private var spectrum: AudioSampleBuffer?

    init(settings: AudioSettings) {
        self.settings = settings
        buildGraph()
        applyEQ()
    }

    deinit {
        ticker?.cancel()
        fadeTask?.cancel()
    }

    /// Cheap here: the engine already has the samples in a tappable graph, so this is
    /// one block on the mixer rather than the C tap the streaming output needs.
    func setSpectrumSink(_ buffer: AudioSampleBuffer?) {
        // Installed once and left alone: removing and reinstalling a tap on a running
        // engine is audible, which is what made switching player modes click.
        guard let buffer, spectrum == nil else { return }
        spectrum = buffer

        let format = mixer.outputFormat(forBus: 0)
        mixer.installTap(onBus: 0, bufferSize: 1024, format: format) { audioBuffer, _ in
            // Audio thread. One channel, one copy, nothing else.
            guard let channel = audioBuffer.floatChannelData?[0] else { return }
            buffer.write(channel, count: Int(audioBuffer.frameLength))
        }
    }

    /// True when every track in the window is a local file, which is the only case
    /// this output can serve at all.
    func canServe(_ songs: [Song]) -> Bool {
        guard let locate, !songs.isEmpty else { return false }
        return songs.allSatisfy { locate($0)?.isLocal == true }
    }

    // MARK: - Graph

    private func buildGraph() {
        engine.attach(mixer)
        engine.attach(eq)
        for player in players { engine.attach(player) }
        connectGraph()

        for (index, frequency) in AudioSettings.bandFrequencies.enumerated() {
            let band = eq.bands[index]
            band.filterType = .parametric
            band.frequency = frequency
            band.bandwidth = 1.0
            band.bypass = false
        }
    }

    /// Wires the fixed links at the **hardware** sample rate.
    ///
    /// This was hardcoded to 44.1 kHz, which quietly resampled every 48 kHz and 96 kHz
    /// FLAC down to 44.1 and then back up to whatever the hardware wanted -- two
    /// conversions and a real loss, on a library that is 22,000 lossless files. Running
    /// the graph at the output rate means the only conversion is the one the OS would
    /// have done anyway.
    private func connectGraph() {
        let sessionRate = AVAudioSession.sharedInstance().sampleRate
        graphRate = sessionRate > 0 ? sessionRate : 48000

        guard let format = AVAudioFormat(standardFormatWithSampleRate: graphRate, channels: 2)
        else { return }

        engine.connect(mixer, to: eq, format: format)
        engine.connect(eq, to: engine.mainMixerNode, format: format)

        // `format: nil` on the inputs is deliberate: each player node adopts its file's
        // own format and the mixer converts. That is what lets a 96 kHz FLAC follow a
        // 44.1 kHz MP3 without rebuilding the graph between tracks.
        for (index, player) in players.enumerated() {
            engine.connect(player, to: mixer, fromBus: 0, toBus: index, format: nil)
        }
    }

    /// Called on every settings change; safe while running, which is what makes the
    /// sliders feel live.
    func applyEQ() {
        for (index, gain) in settings.gains.enumerated() where eq.bands.indices.contains(index) {
            eq.bands[index].gain = gain
        }
        eq.bypass = settings.isFlat
    }

    private func startEngineIfNeeded() {
        guard !engine.isRunning else { return }

        // Rewire if the hardware moved -- plugging in headphones or switching to
        // AirPlay can change the output rate, and a stale graph would resample.
        let sessionRate = AVAudioSession.sharedInstance().sampleRate
        if sessionRate > 0, abs(sessionRate - graphRate) > 1 {
            connectGraph()
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            // Nothing useful to do here: the controller will notice playback is not
            // advancing and can fall back. Never crash over an audio graph.
            isRunning = false
        }
    }

    // MARK: - Loading

    func load(window songs: [Song], startAt: Double) {
        stopNodes()
        window = songs
        hasScheduledNext = false
        activeIndex = 0

        guard let current = songs.first, let file = openFile(current) else {
            duration = 0
            elapsed = 0
            return
        }

        sampleRate = file.processingFormat.sampleRate
        duration = Double(file.length) / sampleRate
        schedule(file, on: activePlayer, songID: current.id, fromSeconds: startAt)
        elapsed = startAt
        startTicker()
    }

    func updateUpcoming(_ songs: [Song]) {
        // Only the tail changes, and the next track has not been scheduled yet unless
        // a crossfade is already under way -- in which case it is too late to change.
        guard let current = window.first else { return }
        window = [current] + songs
        if !hasScheduledNext { return }
    }

    private func openFile(_ song: Song) -> AVAudioFile? {
        guard let location = locate?(song), location.isLocal else { return nil }
        return try? AVAudioFile(forReading: location.url)
    }

    /// Schedules a file from a time offset, and records what is on the node so the
    /// completion callback can be attributed to a song.
    private func schedule(
        _ file: AVAudioFile,
        on player: AVAudioPlayerNode,
        songID: String,
        fromSeconds seconds: Double
    ) {
        let rate = file.processingFormat.sampleRate
        let from = AVAudioFramePosition(max(0, seconds) * rate)
        let remaining = AVAudioFrameCount(max(0, file.length - from))
        guard remaining > 0 else { return }

        let nodeIndex = players.firstIndex(of: player) ?? 0
        songOnNode[nodeIndex] = songID
        if player === activePlayer { startFrame = from }

        startEngineIfNeeded()

        player.scheduleSegment(
            file,
            startingFrame: from,
            frameCount: remaining,
            at: nil,
            completionCallbackType: .dataPlayedBack
        ) { @Sendable [weak self] _ in
            // `@Sendable` so the closure does not inherit this type's `@MainActor`
            // isolation: it is delivered on an internal audio thread, where an
            // inherited-isolation check traps instead of hopping.
            Task { @MainActor [weak self] in
                self?.nodeFinished(nodeIndex: nodeIndex, songID: songID)
            }
        }
    }

    // MARK: - Transport

    func play() {
        startEngineIfNeeded()
        activePlayer.play()
        // A crossfade in progress means the other node is audible too.
        if idlePlayer.isPlaying == false, songOnNode[1 - activeIndex] != nil, fadeTask != nil {
            idlePlayer.play()
        }
        isRunning = true
        startTicker()
    }

    func pause() {
        // `pause` rather than `stop`: stop discards the schedule, so resuming would
        // need the whole file rescheduled and would lose the position.
        for player in players { player.pause() }
        isRunning = false
        ticker?.cancel()
        ticker = nil
    }

    func seek(to seconds: Double) {
        guard let current = window.first, let file = openFile(current) else { return }

        let wasPlaying = isRunning
        fadeTask?.cancel()
        fadeTask = nil
        hasScheduledNext = false

        for player in players { player.stop() }
        for index in songOnNode.indices where index != activeIndex { songOnNode[index] = nil }
        setNodeVolumes(active: 1, idle: 0)

        schedule(file, on: activePlayer, songID: current.id, fromSeconds: seconds)
        elapsed = seconds

        if wasPlaying {
            activePlayer.play()
            startTicker()
        }
    }

    func stop() {
        stopNodes()
        window = []
        elapsed = 0
        duration = 0
        if engine.isRunning { engine.stop() }
    }

    private func stopNodes() {
        fadeTask?.cancel()
        fadeTask = nil
        ticker?.cancel()
        ticker = nil
        isRunning = false
        for player in players { player.stop() }
        songOnNode = [nil, nil]
        setNodeVolumes(active: 1, idle: 0)
        startFrame = 0
    }

    private func setNodeVolumes(active: Float, idle: Float) {
        activePlayer.volume = active
        idlePlayer.volume = idle
    }

    // MARK: - Time and transitions

    private func startTicker() {
        ticker?.cancel()
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                guard let self, !Task.isCancelled else { return }
                tick()
            }
        }
    }

    private func tick() {
        guard let nodeTime = activePlayer.lastRenderTime,
              let playerTime = activePlayer.playerTime(forNodeTime: nodeTime)
        else {
            onTick?(elapsed, false)
            return
        }

        let rate = playerTime.sampleRate > 0 ? playerTime.sampleRate : sampleRate
        elapsed = Double(startFrame + playerTime.sampleTime) / rate
        onTick?(elapsed, activePlayer.isPlaying)

        beginCrossfadeIfDue()
    }

    /// Starts the overlap when the current track is within the crossfade window.
    ///
    /// With crossfade at 0 nothing happens here: the next track is scheduled on the
    /// same node by `nodeFinished` instead, back-to-back, which is gapless.
    private func beginCrossfadeIfDue() {
        let overlap = settings.crossfadeSeconds
        guard overlap > 0, !hasScheduledNext, isRunning, duration > 0,
              window.count > 1,
              duration - elapsed <= overlap
        else { return }

        guard let next = window.dropFirst().first, let file = openFile(next) else { return }

        hasScheduledNext = true
        let incoming = idlePlayer
        let incomingIndex = 1 - activeIndex

        songOnNode[incomingIndex] = next.id
        incoming.volume = 0
        schedule(file, on: incoming, songID: next.id, fromSeconds: 0)
        incoming.play()

        fadeTask?.cancel()
        fadeTask = Task { [weak self] in
            let steps = 40
            for step in 1...steps {
                guard let self, !Task.isCancelled else { return }
                let fraction = Float(step) / Float(steps)
                // Equal-power rather than linear: a linear pair dips ~3 dB in the
                // middle, which is audible as a hole in the transition.
                incoming.volume = sin(fraction * .pi / 2)
                players[activeIndex].volume = cos(fraction * .pi / 2)
                try? await Task.sleep(for: .seconds(overlap / Double(steps)))
            }
        }
    }

    /// A node reached the end of what was scheduled on it.
    private func nodeFinished(nodeIndex: Int, songID: String) {
        // Ignore a stale callback: a seek or a queue edit stops nodes, and stopping
        // fires the same completion.
        guard songOnNode[nodeIndex] == songID else { return }
        songOnNode[nodeIndex] = nil

        if nodeIndex != activeIndex {
            // The outgoing node in a crossfade finished; the incoming one is already
            // the current track.
            return
        }

        if hasScheduledNext {
            // Crossfade already handed over: the other node is playing the next track,
            // so just follow it.
            handOverToIdleNode()
            return
        }

        advanceGapless()
    }

    /// Crossfade case: the incoming node becomes the active one.
    private func handOverToIdleNode() {
        let previous = activeIndex
        activeIndex = 1 - previous
        players[previous].stop()
        players[previous].volume = 1
        activePlayer.volume = 1

        startFrame = 0
        hasScheduledNext = false

        let songID = songOnNode[activeIndex]
        window = Array(window.dropFirst())
        if let current = window.first, let file = openFile(current) {
            duration = Double(file.length) / file.processingFormat.sampleRate
        }
        onAdvanced?(songID)
    }

    /// Gapless case: schedule the next track on the same node the instant this one
    /// ends. `AVAudioPlayerNode` renders consecutive schedules with no gap.
    private func advanceGapless() {
        guard window.count > 1 else {
            isRunning = false
            onAdvanced?(nil)
            return
        }

        window = Array(window.dropFirst())
        guard let current = window.first, let file = openFile(current) else {
            onAdvanced?(nil)
            return
        }

        sampleRate = file.processingFormat.sampleRate
        duration = Double(file.length) / sampleRate
        startFrame = 0
        schedule(file, on: activePlayer, songID: current.id, fromSeconds: 0)
        if isRunning { activePlayer.play() }
        onAdvanced?(current.id)
    }
}
