import GameController

// Watches for connected game controllers and maps their input to app actions.
// Directional input routes through DirectionalRepeater (below) for a console-style
// press/hold feel; buttons route through ControllerMappingStore so the user's own
// button layout (Settings ▸ Controller) decides what each press means.
@MainActor
final class ControllerInput {
    private weak var appState: AppState?
    private var musicStick: MusicStickController?
    private var observers: [Any] = []

    // One repeater per movement axis (stick X/Y and d-pad X/Y share them, so a stick hold
    // and a d-pad hold feel identical and can't double-fire against each other).
    private lazy var horizontal = DirectionalRepeater { [weak self] positive in
        self?.fire(positive ? .navRight : .navLeft)
    }
    private lazy var vertical = DirectionalRepeater { [weak self] positive in
        self?.fire(positive ? .navUp : .navDown)
    }

    init() {
        // Discover Bluetooth controllers in range.
        GCController.startWirelessControllerDiscovery {}

        observers.append(
            NotificationCenter.default.addObserver(
                forName: .GCControllerDidConnect,
                object: nil,
                queue: .main
            ) { [weak self] note in
                guard let controller = note.object as? GCController else { return }
                Task { @MainActor [weak self] in self?.wire(controller) }
            }
        )
        observers.append(
            NotificationCenter.default.addObserver(
                forName: .GCControllerDidDisconnect,
                object: nil,
                queue: .main
            ) { _ in }  // could show a HUD later
        )
        // Wire already-connected controllers (Task ensures main-actor isolation)
        let existing = GCController.controllers()
        Task { @MainActor [weak self] in existing.forEach { self?.wire($0) } }
    }

    func bind(to appState: AppState, musicPlayer: MusicPlayerController) {
        self.appState = appState
        self.musicStick = MusicStickController(musicPlayer: musicPlayer)
    }

    deinit {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        GCController.stopWirelessControllerDiscovery()
    }

    // MARK: - Wiring

    private func wire(_ controller: GCController) {
        guard let pad = controller.extendedGamepad else { return }

        // D-pad — a press steps once immediately; holding it repeats after a beat, same as the
        // sticks (the repeater treats a held direction as a full-tilt axis).
        pad.dpad.left.pressedChangedHandler  = { [weak self] _, _, pressed in
            self?.horizontal.update(pressed ? -1 : 0)
        }
        pad.dpad.right.pressedChangedHandler = { [weak self] _, _, pressed in
            self?.horizontal.update(pressed ? 1 : 0)
        }
        pad.dpad.up.pressedChangedHandler    = { [weak self] _, _, pressed in
            self?.vertical.update(pressed ? 1 : 0)
        }
        pad.dpad.down.pressedChangedHandler  = { [weak self] _, _, pressed in
            self?.vertical.update(pressed ? -1 : 0)
        }

        // Left thumbstick — same repeaters, driven by the live analog value so the repeat
        // rate can track how far the stick is pushed.
        pad.leftThumbstick.xAxis.valueChangedHandler = { [weak self] _, value in
            self?.horizontal.update(value)
        }
        pad.leftThumbstick.yAxis.valueChangedHandler = { [weak self] _, value in
            self?.vertical.update(value)
        }

        // Right thumbstick — always the music player, in every view/focus zone (couch-mode
        // convenience: adjust music without leaving whatever you're browsing). Y = volume,
        // X = track skip (tap) / seek (hold), click = play/pause. See MusicStickController.
        pad.rightThumbstick.yAxis.valueChangedHandler = { [weak self] _, value in
            self?.musicStick?.updateVolume(value)
        }
        pad.rightThumbstick.xAxis.valueChangedHandler = { [weak self] _, value in
            self?.musicStick?.updateSkipSeek(value)
        }
        pad.rightThumbstickButton?.pressedChangedHandler = { [weak self] _, _, pressed in
            if pressed { self?.musicStick?.togglePlayPause() }
        }

        // Every remappable button funnels through press(_:) — what a press DOES is decided
        // there by the user's mapping, not by which handler it came in on.
        var buttons: [(GCControllerButtonInput, ControllerButton)] = [
            (pad.buttonA, .a), (pad.buttonB, .b), (pad.buttonX, .x), (pad.buttonY, .y),
            (pad.leftShoulder, .leftShoulder), (pad.rightShoulder, .rightShoulder),
            (pad.leftTrigger, .leftTrigger), (pad.rightTrigger, .rightTrigger),
            (pad.buttonMenu, .menu),
        ]
        if let options = pad.buttonOptions { buttons.append((options, .options)) }
        for (input, button) in buttons {
            input.pressedChangedHandler = { [weak self] _, _, pressed in
                self?.press(button, pressed: pressed)
            }
        }
    }

    // MARK: - Actions

    // `pressed: false` (release) is only meaningful for the confirm-mapped button — a PLAY
    // hold-to-confirm in progress needs to know when the button is let go early, since every
    // other action already fires its full effect on the press edge alone. See decisions.md #96.
    private func press(_ button: ControllerButton, pressed: Bool) {
        let mapping = ControllerMappingStore.shared
        // Settings' remap UI is listening for "press any button" — feed it the press instead
        // of navigating the app underneath the capture prompt.
        if let target = mapping.captureTarget {
            if pressed { mapping.assign(button, to: target) }
            return
        }
        guard let action = mapping.action(for: button) else { return }   // unbound button
        if pressed {
            fire(action.controllerAction)
        } else if action == .confirm {
            fire(.confirmReleased)
        }
    }

    private func fire(_ action: ControllerAction) {
        guard let appState else { return }
        appState.lastInputMethod = .controller
        appState.controllerAction = action
    }
}

// Console-style directional auto-repeat with hysteresis. The old behavior (fire, then a flat
// 250ms cooldown that auto-cleared while still held) made a quick flick land 2+ steps —
// anything held past 250ms fired again, so precise single steps needed the d-pad instead.
// The fix is the classic key-repeat envelope every console UI uses:
//   • crossing the engage threshold fires ONE step instantly (flicks are precise by design)
//   • repeats only begin after a distinct initial delay (a flick is long over by then)
//   • then a steady repeat rate, faster at full tilt than at partial tilt
//   • disengage uses a LOWER threshold than engage, so a stick hovering right at the edge
//     can't chatter engage/disengage and double-fire
@MainActor
final class DirectionalRepeater {
    private let engageThreshold: Float = 0.5
    private let releaseThreshold: Float = 0.3
    private let initialDelay: UInt64 = 400_000_000     // 400ms before the first repeat
    private let fullTiltInterval: UInt64 = 130_000_000 // ~7.7 steps/sec pegged
    private let partialInterval: UInt64 = 240_000_000  // ~4 steps/sec at a gentle push

    private let step: (Bool) -> Void   // true = positive direction
    private var value: Float = 0
    private var engaged = false
    private var repeatTask: Task<Void, Never>?

    init(step: @escaping (Bool) -> Void) {
        self.step = step
    }

    func update(_ newValue: Float) {
        value = newValue
        if !engaged, abs(newValue) >= engageThreshold {
            engaged = true
            step(newValue > 0)
            startRepeating()
        } else if engaged, abs(newValue) < releaseThreshold {
            engaged = false
            repeatTask?.cancel()
            repeatTask = nil
        }
    }

    private func startRepeating() {
        repeatTask?.cancel()
        repeatTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: self.initialDelay)
            while !Task.isCancelled, self.engaged {
                self.step(self.value > 0)
                let interval = abs(self.value) > 0.9 ? self.fullTiltInterval : self.partialInterval
                try? await Task.sleep(nanoseconds: interval)
            }
        }
    }
}

// Right thumbstick → music player, wired unconditionally in every focus zone (v0.25.0, Jack's
// ask: adjust music without leaving whatever you're browsing). Y axis is a continuous volume
// ramp — proportional to tilt, so a gentle push trims the volume finely and a full push races
// it — while X axis distinguishes a quick flick (skip a track, matching the on-screen prev/next
// buttons) from a HELD push (seek through the current track) by racing a short timer against
// the release: still held once the timer fires means "seek," not "skip." Both axes are
// independent state machines (no shared repeater) since their feel — continuous ramp vs.
// tap/hold-with-a-deadline — doesn't match DirectionalRepeater's console d-pad envelope at all.
@MainActor
final class MusicStickController {
    private weak var musicPlayer: MusicPlayerController?
    private let deadzone: Float = 0.25

    // With the music player switched off in Preferences the widget isn't on screen at all, so
    // the right stick has nothing to drive — every entry point bails rather than silently
    // moving a hidden volume slider.
    private var musicAvailable: Bool { musicPlayer?.isEnabled == true }

    init(musicPlayer: MusicPlayerController?) {
        self.musicPlayer = musicPlayer
    }

    // MARK: - Volume (Y axis)

    private var volumeValue: Float = 0
    private var volumeTask: Task<Void, Never>?

    func updateVolume(_ value: Float) {
        guard musicAvailable else { return }
        volumeValue = value
        guard abs(value) >= deadzone else {
            volumeTask?.cancel()
            volumeTask = nil
            return
        }
        guard volumeTask == nil, let musicPlayer else { return }
        musicPlayer.beginStickInteraction()
        volumeTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled, abs(self.volumeValue) >= self.deadzone {
                guard let player = self.musicPlayer else { break }
                let delta = 0.015 * self.volumeValue   // up (+1) = louder, down (-1) = quieter
                player.setVolume(max(0, min(1, player.volume + delta)))
                try? await Task.sleep(nanoseconds: 60_000_000)
            }
            self.volumeTask = nil
            self.musicPlayer?.endStickInteraction()
        }
    }

    // MARK: - Track skip / seek (X axis)

    private var xEngaged = false
    private var seekDirectionPositive = true
    private var isSeeking = false
    private var tapDeadlineTask: Task<Void, Never>?
    private var seekTask: Task<Void, Never>?
    private static let tapWindow: UInt64 = 350_000_000   // held past this = seek, not a skip

    func updateSkipSeek(_ value: Float) {
        guard musicAvailable else { return }
        if !xEngaged, abs(value) >= deadzone {
            xEngaged = true
            isSeeking = false
            seekDirectionPositive = value > 0
            musicPlayer?.beginStickInteraction()
            tapDeadlineTask?.cancel()
            tapDeadlineTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: Self.tapWindow)
                guard let self, !Task.isCancelled, self.xEngaged else { return }
                self.isSeeking = true
                self.startSeeking()
            }
        } else if xEngaged, abs(value) < deadzone {
            xEngaged = false
            tapDeadlineTask?.cancel()
            tapDeadlineTask = nil
            if isSeeking {
                isSeeking = false
                seekTask?.cancel()
                seekTask = nil
            } else {
                // Released within the tap window — a quick flick, same as the on-screen buttons.
                if seekDirectionPositive { musicPlayer?.nextTrack() } else { musicPlayer?.previousTrack() }
            }
            musicPlayer?.endStickInteraction()
        }
    }

    private func startSeeking() {
        seekTask?.cancel()
        seekTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled, self.xEngaged {
                guard let player = self.musicPlayer else { break }
                let step: TimeInterval = self.seekDirectionPositive ? 3.0 : -3.0
                player.seek(to: max(0, min(player.duration, player.currentTime + step)))
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
        }
    }

    // MARK: - Click (R3)

    func togglePlayPause() {
        guard musicAvailable else { return }
        musicPlayer?.expand()
        musicPlayer?.toggle()
    }
}
