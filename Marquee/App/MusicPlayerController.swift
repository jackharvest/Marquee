import Foundation
import AVFoundation
import Accelerate
import SwiftUI

// MARK: - Audio Engine (not isolated — runs on audio thread for FFT processing)

private final class AudioEngine: @unchecked Sendable {
    let engine   = AVAudioEngine()
    let player   = AVAudioPlayerNode()

    private let fftN      = 2048
    private let barCount  = 16
    private var fftSetup: FFTSetup?
    private var smoothedBars = [Float](repeating: 0, count: 16)
    private var hannWindow   = [Float](repeating: 0, count: 2048)

    var onBarsUpdated: (([Float]) -> Void)?

    init() {
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: nil)
        engine.mainMixerNode.outputVolume = 0.3

        let log2n = vDSP_Length(log2(Double(fftN)))
        fftSetup  = vDSP_create_fftsetup(log2n, FFTRadix(FFT_RADIX2))
        vDSP_hann_window(&hannWindow, vDSP_Length(fftN), Int32(vDSP_HANN_NORM))

        let format = engine.mainMixerNode.outputFormat(forBus: 0)
        engine.mainMixerNode.installTap(
            onBus: 0,
            bufferSize: AVAudioFrameCount(fftN),
            format: format
        ) { [weak self] buffer, _ in
            self?.processTap(buffer)
        }
    }

    deinit {
        engine.mainMixerNode.removeTap(onBus: 0)
        if let s = fftSetup { vDSP_destroy_fftsetup(s) }
    }

    func start() throws { try engine.start() }

    private func processTap(_ buffer: AVAudioPCMBuffer) {
        guard let fftSetup,
              let channelData = buffer.floatChannelData?[0] else { return }

        let n     = fftN
        let halfN = n / 2

        // Fill sample array — zero-pad if buffer is smaller than fftN
        var samples = [Float](repeating: 0, count: n)
        let copyCount = min(Int(buffer.frameLength), n)
        samples.withUnsafeMutableBufferPointer {
            $0.baseAddress!.initialize(from: channelData, count: copyCount)
        }

        // Apply Hann window (reduces spectral leakage)
        vDSP_vmul(samples, 1, hannWindow, 1, &samples, 1, vDSP_Length(n))

        // Pack N real samples into N/2 split-complex for half-length real FFT
        var realp = [Float](repeating: 0, count: halfN)
        var imagp = [Float](repeating: 0, count: halfN)
        var mags  = [Float](repeating: 0, count: halfN)

        samples.withUnsafeBufferPointer { sPtr in
            realp.withUnsafeMutableBufferPointer { rPtr in
                imagp.withUnsafeMutableBufferPointer { iPtr in
                    var sc = DSPSplitComplex(realp: rPtr.baseAddress!, imagp: iPtr.baseAddress!)
                    sPtr.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: halfN) {
                        vDSP_ctoz($0, 2, &sc, 1, vDSP_Length(halfN))
                    }
                    let log2n = vDSP_Length(log2(Double(n)))
                    vDSP_fft_zrip(fftSetup, &sc, 1, log2n, FFTDirection(FFT_FORWARD))
                    vDSP_zvmags(&sc, 1, &mags, 1, vDSP_Length(halfN))
                }
            }
        }

        // Normalize power by N^2 so a full-scale signal → ~1.0 per bin
        var scale = Float(4.0) / Float(n * n)
        vDSP_vsmul(mags, 1, &scale, &mags, 1, vDSP_Length(halfN))

        // Map 1024 FFT bins to 16 bars with logarithmic frequency spacing
        let sampleRate = Float(engine.mainMixerNode.outputFormat(forBus: 0).sampleRate)
        let binWidth   = sampleRate / Float(n)
        let minFreq: Float = 55      // A1 — bottom of bass
        let maxFreq: Float = 16_000  // top of presence/air

        var bars = [Float](repeating: 0, count: barCount)
        for i in 0..<barCount {
            let t0 = Float(i)     / Float(barCount)
            let t1 = Float(i + 1) / Float(barCount)
            let lo = Int(minFreq * pow(maxFreq / minFreq, t0) / binWidth).clamped(to: 1..<halfN)
            let hi = Int(minFreq * pow(maxFreq / minFreq, t1) / binWidth).clamped(to: 1..<halfN)
            guard lo <= hi else { continue }

            var avg: Float = 0
            mags.withUnsafeBufferPointer { ptr in
                vDSP_meanv(ptr.baseAddress!.advanced(by: lo), 1, &avg, vDSP_Length(hi - lo + 1))
            }

            // Aggressive power-law + boost so typical music fills 70-100% of bar
            bars[i] = min(1.0, pow(avg, 0.15) * 3.0)
        }

        // Smooth: fast attack (30% old), slower decay (85% old)
        for i in 0..<barCount {
            let alpha: Float = bars[i] > smoothedBars[i] ? 0.30 : 0.85
            smoothedBars[i] = smoothedBars[i] * alpha + bars[i] * (1 - alpha)
        }

        let result = smoothedBars
        DispatchQueue.main.async { [weak self] in
            self?.onBarsUpdated?(result)
        }
    }
}

private extension Int {
    func clamped(to range: Range<Int>) -> Int { Swift.max(range.lowerBound, Swift.min(self, range.upperBound - 1)) }
}

// MARK: - Music Player Controller

@Observable
@MainActor
final class MusicPlayerController {
    private let audio = AudioEngine()

    var isPlaying        = false
    // Mirrors AppState.windowVisible (set by MarqueeApp) — see the guard in `onBarsUpdated`
    // above for why. Defaults true so playback/visualizer behave normally before the first sync.
    var isWindowVisible  = true
    var currentTrackIndex = 0
    // Sticky (v0.20.0): persists across launches — Preferences and the widget's own drag-to-set
    // scrubber both funnel through setVolume(_:), which is the one place that writes it back out.
    var volume: Float    = {
        let ud = UserDefaults.standard
        return ud.object(forKey: "musicVolume") == nil ? 0.3 : ud.float(forKey: "musicVolume")
    }()
    var barMagnitudes: [Float] = [Float](repeating: 0, count: 16)
    var isExpanded       = true
    var isStickyEnabled  = false
    // Master switch for the whole feature: off hides the bottom-left widget
    // entirely and never starts playback. Not everyone wants a song when they're opening the
    // launcher to start a game — and the widget sits over the bottom-left corner of the library,
    // so "I don't use this" and "it's in my way" are the same complaint. Everything else in this
    // controller keeps working untouched; only `init` and `setEnabled` consult it, so there's no
    // second code path to keep in sync.
    var isEnabled: Bool = MusicPlayerController.enabledPreference

    // The same flag read straight from UserDefaults, for the places that need it without a live
    // controller instance in hand (the pause menu builds its row list from a static context).
    // `setEnabled` writes it, so this never disagrees with the instance property.
    static var enabledPreference: Bool {
        let ud = UserDefaults.standard
        return ud.object(forKey: "musicPlayerEnabled") == nil ? true : ud.bool(forKey: "musicPlayerEnabled")
    }
    var trackWeights: [Int] = []   // 0=off, 50=low, 100=normal, 150=high, 200=2×

    private var trackURLs:    [URL]    = []
    private(set) var trackNames: [String] = []
    private var customTrackURLs: [URL] = []
    private var bundleTrackCount: Int = 0
    private var isPaused      = false

    // Playback position tracking (for the progress bar / time labels).
    private(set) var duration: TimeInterval = 0
    private var currentFile: AVAudioFile?
    private var fileSampleRate: Double = 44_100
    // Seconds into the track where the current schedule began. Combined with the
    // player node's own sample clock (which resets on stop()) this yields elapsed time
    // and survives seeking.
    private var seekOffset: TimeInterval = 0

    // Live elapsed time within the current track, clamped to [0, duration].
    var currentTime: TimeInterval {
        guard duration > 0 else { return 0 }
        guard let nodeTime = audio.player.lastRenderTime,
              let pt = audio.player.playerTime(forNodeTime: nodeTime), pt.sampleRate > 0 else {
            return min(max(0, seekOffset), duration)
        }
        let played = Double(pt.sampleTime) / pt.sampleRate
        return min(max(0, seekOffset + played), duration)
    }
    // Incremented on every intentional stop so stale completion handlers are ignored.
    // When player.stop() cancels a scheduled file it fires that file's completion handler
    // immediately — without this guard that triggers advance() → infinite loop.
    private var playGeneration = 0
    private var stickyTrackIndex: Int?

    init() {
        loadTracks()

        // AVAudioEngine keeps its I/O thread (and this tap) running continuously once started —
        // pause() only stops the player NODE, not the engine, so without this guard the tap
        // keeps firing on silence at ~21Hz and unconditionally writing an @Observable property
        // forever, which forces a real SwiftUI/AttributeGraph re-render+layout pass on every
        // single write — discovered as the dominant driver of Marquee's idle CPU use while
        // paused/minimized (traced via `sample`: NSHostingView.layout() → ViewGraphRootValueUpdater
        // .render(...) running continuously even with the window miniaturized and motion/hero/
        // carousel-rendering all separately gated off). Skipping the write entirely when nothing
        // is actually playing OR the window isn't visible costs nothing (the bars just hold
        // their last — already near-zero, since they decay — value) and eliminates that cost.
        audio.onBarsUpdated = { [weak self] bars in
            guard let self, self.isPlaying, self.isWindowVisible else { return }
            self.barMagnitudes = bars
        }

        try? audio.start()

        loadStickyPreference()
        guard isEnabled else { return }
        let trackToPlay = stickyTrackIndex ?? pickWeightedRandom(excluding: nil)
        playTrack(at: trackToPlay)
    }

    // Turning it back on starts the same track the app would have opened with; turning it off
    // stops playback outright rather than pausing, so nothing lingers behind a hidden widget.
    func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        isEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "musicPlayerEnabled")
        if enabled {
            playTrack(at: stickyTrackIndex ?? pickWeightedRandom(excluding: nil))
            isExpanded = true
            scheduleAutoMinimize()
        } else {
            playGeneration += 1        // swallow the completion handler stop() fires
            audio.player.stop()
            isPlaying = false
            isPaused  = false
            barMagnitudes = [Float](repeating: 0, count: barMagnitudes.count)
        }
    }

    // MARK: - Track Loading

    private func loadTracks() {
        let bundleURLs = (1...11).compactMap {
            Bundle.main.url(forResource: "Marquee_BGSong\($0)", withExtension: "mp3")
        }

        // Load user-imported tracks from Application Support/Marquee/Music/
        var importedURLs: [URL] = []
        let musicDir = Self.customMusicDir
        if let contents = try? FileManager.default.contentsOfDirectory(
            at: musicDir, includingPropertiesForKeys: nil, options: .skipsHiddenFiles
        ) {
            let audioExts: Set<String> = ["mp3", "m4a", "aac", "wav", "flac", "ogg", "aiff"]
            importedURLs = contents
                .filter { audioExts.contains($0.pathExtension.lowercased()) }
                .sorted { $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending }
        }

        bundleTrackCount = bundleURLs.count
        customTrackURLs  = importedURLs
        trackURLs        = bundleURLs + importedURLs
        trackNames       = generateTrackNames()
        loadWeights()
    }

    static var customMusicDir: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return appSupport.appendingPathComponent("Marquee/Music")
    }

    private func generateTrackNames() -> [String] {
        var names: [String] = (0..<bundleTrackCount).map { "Song \($0 + 1)" }
        names += customTrackURLs.map { $0.deletingPathExtension().lastPathComponent }
        return names
    }

    private func loadWeights() {
        let stored = UserDefaults.standard.array(forKey: "musicTrackWeights") as? [Int] ?? []
        trackWeights = (0..<trackURLs.count).map { i in
            let v = i < stored.count ? stored[i] : 50
            return min(100, max(0, v))  // clamp: old range was 0-200, new range is 0-100
        }
    }

    private func saveWeights() {
        UserDefaults.standard.set(trackWeights, forKey: "musicTrackWeights")
    }

    func setWeight(_ weight: Int, for index: Int) {
        guard index < trackWeights.count else { return }
        trackWeights[index] = min(100, max(0, weight))
        saveWeights()
    }

    // Weighted random track selection, optionally excluding the current track.
    // Falls back to sequential if all eligible tracks are disabled (weight 0).
    private func pickWeightedRandom(excluding excluded: Int?) -> Int {
        guard !trackURLs.isEmpty else { return 0 }
        let weights = (0..<trackURLs.count).map { i -> Int in
            if let ex = excluded, i == ex { return 0 }
            return max(0, trackWeights.indices.contains(i) ? trackWeights[i] : 50)
        }
        let total = weights.reduce(0, +)
        guard total > 0 else {
            let all = Array(0..<trackURLs.count)
            let eligible = excluded.map { ex in all.filter { $0 != ex } } ?? all
            guard !eligible.isEmpty else { return 0 }
            return eligible[Int.random(in: 0..<eligible.count)]
        }
        var r = Int.random(in: 0..<total)
        for (i, w) in weights.enumerated() { r -= w; if r < 0 { return i } }
        return 0
    }

    func importTrack(url: URL) {
        let dir = Self.customMusicDir
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var dest = dir.appendingPathComponent(url.lastPathComponent)
        if FileManager.default.fileExists(atPath: dest.path) {
            let base = url.deletingPathExtension().lastPathComponent
            let ext  = url.pathExtension
            dest = dir.appendingPathComponent("\(base)_\(Int.random(in: 1000...9999)).\(ext)")
        }
        try? FileManager.default.copyItem(at: url, to: dest)
        loadTracks()
    }

    var currentTrackName: String {
        trackNames.indices.contains(currentTrackIndex) ? trackNames[currentTrackIndex] : "—"
    }

    // MARK: - Playback

    func playTrack(at index: Int) {
        guard !trackURLs.isEmpty else { return }
        let idx = ((index % trackURLs.count) + trackURLs.count) % trackURLs.count
        guard let file = try? AVAudioFile(forReading: trackURLs[idx]) else { return }

        // Bump generation BEFORE stop() — stop() synchronously fires the old file's
        // completion handler; the stale generation value makes that call a no-op.
        playGeneration += 1
        let gen = playGeneration

        audio.player.stop()
        audio.player.scheduleFile(file, at: nil) { [weak self] in
            DispatchQueue.main.async {
                guard let self, self.playGeneration == gen else { return }
                self.advance()
            }
        }
        audio.player.volume = volume
        if !audio.engine.isRunning { try? audio.start() }
        audio.player.play()
        isPlaying         = true
        isPaused          = false
        currentTrackIndex = idx

        currentFile    = file
        fileSampleRate = file.processingFormat.sampleRate
        duration       = fileSampleRate > 0 ? Double(file.length) / fileSampleRate : 0
        seekOffset     = 0
    }

    // Jump to an absolute time in the current track. Reschedules the remaining audio as a
    // segment and records the offset so `currentTime` stays accurate.
    func seek(to time: TimeInterval) {
        guard let file = currentFile, fileSampleRate > 0, duration > 0 else { return }
        let target     = max(0, min(time, duration))
        let startFrame = AVAudioFramePosition(target * fileSampleRate)
        let remaining  = file.length - startFrame
        guard remaining > 0 else { advance(); return }

        playGeneration += 1
        let gen = playGeneration

        audio.player.stop()
        audio.player.scheduleSegment(
            file, startingFrame: startFrame,
            frameCount: AVAudioFrameCount(remaining), at: nil
        ) { [weak self] in
            DispatchQueue.main.async {
                guard let self, self.playGeneration == gen else { return }
                self.advance()
            }
        }
        if !audio.engine.isRunning { try? audio.start() }
        audio.player.volume = volume
        audio.player.play()
        seekOffset = target
        isPlaying  = true
        isPaused   = false
    }

    func toggle() {
        if isPlaying {
            audio.player.pause()
            isPlaying = false
            isPaused  = true
        } else {
            if !audio.engine.isRunning { try? audio.start() }
            if isPaused {
                // Resume from the exact position where we paused.
                // player.isPlaying is false when paused, so we can't use that to distinguish
                // paused-vs-never-started — hence the explicit isPaused flag.
                audio.player.play()
                isPlaying = true
                isPaused  = false
            } else {
                playTrack(at: currentTrackIndex)
            }
        }
    }

    func nextTrack()     { noteInteraction(); playTrack(at: currentTrackIndex + 1) }
    func previousTrack() { noteInteraction(); playTrack(at: currentTrackIndex - 1) }

    // MARK: - Auto-minimize
    //
    // The expanded widget covers content in several views, so it auto-collapses after a
    // period of inactivity. Any interaction (or hover) restarts the countdown; navigating
    // to the widget re-expands it. Suspended while the keyboard/controller focus is on it.
    private var autoMinimizeTask: Task<Void, Never>?
    var autoMinimizeSuspended = false

    func scheduleAutoMinimize(after seconds: Double = 15) {
        autoMinimizeTask?.cancel()
        guard isExpanded, !autoMinimizeSuspended, !stickInteractionActive else { return }
        autoMinimizeTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled, let self, self.isExpanded, !self.autoMinimizeSuspended,
                  !self.stickInteractionActive else { return }
            withAnimation(.spring(response: 0.28, dampingFraction: 0.80)) { self.isExpanded = false }
        }
    }

    func cancelAutoMinimize() { autoMinimizeTask?.cancel(); autoMinimizeTask = nil }

    // Re-expand (e.g. when navigation focus moves onto the widget) and restart the timer.
    func expand() {
        withAnimation(.spring(response: 0.28, dampingFraction: 0.80)) { isExpanded = true }
        scheduleAutoMinimize()
    }

    // Any user interaction with the widget restarts the inactivity countdown.
    func noteInteraction() { if isExpanded { scheduleAutoMinimize() } }

    // MARK: - Right-stick interaction (v0.29.0)
    //
    // The right thumbstick drives volume/skip/seek unconditionally in every focus zone (couch-
    // mode convenience, v0.25.0) — but that meant nudging it while the widget had already
    // auto-minimized (or was never expanded) changed the volume/track with nothing on screen to
    // show for it: `noteInteraction()` only RESCHEDULES the countdown if already expanded, it
    // never forces the widget visible the way clicking an expanded control implies. A separate
    // flag (not `autoMinimizeSuspended`, which the keyboard/controller focus-zone case also
    // uses and could otherwise be prematurely cleared by whichever interaction ends first)
    // keeps the widget pinned open for exactly as long as the stick stays engaged — mirrors the
    // existing mouse-hover pattern (onHover cancels/reschedules) but for a "hold" that isn't a
    // hover at all.
    private(set) var stickInteractionActive = false

    func beginStickInteraction() {
        stickInteractionActive = true
        cancelAutoMinimize()
        if !isExpanded {
            withAnimation(.spring(response: 0.28, dampingFraction: 0.80)) { isExpanded = true }
        }
    }

    func endStickInteraction() {
        stickInteractionActive = false
        scheduleAutoMinimize()
    }

    func setVolume(_ v: Float) {
        volume = v
        audio.player.volume = v
        UserDefaults.standard.set(v, forKey: "musicVolume")
    }

    // MARK: - Game-session fades
    //
    // Used by GameSessionManager when a game launches/quits. These deliberately animate the
    // *output* volume (`audio.player.volume`) only — they never touch `volume`, so the slider
    // stays at the level the user chose and we can fade right back to it on return.

    // Fade the audio out to silence over `duration`, then pause at the faded-out position so the
    // track can later be resumed from the exact same spot. No-op if nothing is playing.
    func fadeOutAndPause(over duration: TimeInterval = 2.0) async {
        guard isPlaying else { return }
        let startVol = audio.player.volume
        let steps = 40
        let interval = duration / Double(steps)
        for i in 1...steps {
            if Task.isCancelled { break }
            audio.player.volume = startVol * Float(steps - i) / Float(steps)
            try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
        }
        audio.player.volume = 0
        audio.player.pause()
        isPlaying = false
        isPaused  = true
    }

    // Resume from the paused position at zero volume and fade back up to the user's level.
    func resumeFadingIn(over duration: TimeInterval = 2.0) async {
        let target = volume
        if !audio.engine.isRunning { try? audio.start() }
        audio.player.volume = 0
        if isPaused {
            audio.player.play()
            isPlaying = true
            isPaused  = false
        } else if !isPlaying {
            playTrack(at: currentTrackIndex)
            audio.player.volume = 0   // playTrack restores full volume; keep silent for the fade
        }
        let steps = 40
        let interval = duration / Double(steps)
        for i in 1...steps {
            if Task.isCancelled { break }
            audio.player.volume = target * Float(i) / Float(steps)
            try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
        }
        audio.player.volume = target
    }

    private func advance() {
        if let sticky = stickyTrackIndex { playTrack(at: sticky); return }
        guard trackURLs.count > 1 else { playTrack(at: 0); return }
        playTrack(at: pickWeightedRandom(excluding: currentTrackIndex))
    }

    func toggleSticky() {
        if isStickyEnabled {
            stickyTrackIndex = nil
            isStickyEnabled = false
        } else {
            stickyTrackIndex = currentTrackIndex
            isStickyEnabled = true
        }
        saveStickyPreference()
    }

    // Read-only accessor for the Preferences window's startup-song picker — mirrors
    // isStickyEnabled but exposes WHICH track, not just whether one is pinned.
    var startupTrackIndex: Int? { stickyTrackIndex }

    // Directly choose (or clear, for "Random") the startup/auto-advance track — same underlying
    // mechanism as toggleSticky(), but settable from Preferences without needing that track to
    // be the one currently playing.
    func setStartupTrack(_ index: Int?) {
        if let index {
            stickyTrackIndex = index
            isStickyEnabled = true
        } else {
            stickyTrackIndex = nil
            isStickyEnabled = false
        }
        saveStickyPreference()
    }

    private func loadStickyPreference() {
        let defaults = UserDefaults.standard
        let key = "musicPlayerStickyTrackIndex"
        if let idx = defaults.object(forKey: key) as? Int {
            stickyTrackIndex = idx
            isStickyEnabled = true
        }
    }

    private func saveStickyPreference() {
        let defaults = UserDefaults.standard
        let key = "musicPlayerStickyTrackIndex"
        if let idx = stickyTrackIndex {
            defaults.set(idx, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }
}
