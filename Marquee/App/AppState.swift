import Foundation
import Observation
import AppKit   // NSImage (banner re-fetch validation), NSOpenPanel (custom library adds)
import UniformTypeIdentifiers

enum ArtSourcePreference {
    case notConfigured, own, automatic, steamGridDB
}

// eShop-style trailer playback commands — ContentView's key/controller router sets these,
// DetailView's TrailerPlayer observes and consumes them (see AppState.trailerCommand).
enum TrailerCommand: Equatable {
    case none, togglePlayPause
    case scrub(seconds: Double)
}

// Tracks which input device the user last used — drives the input-method indicator badge.
enum InputMethod: Equatable { case keyboard, mouse, controller }

// Controller actions — set by ControllerInput, consumed by ContentView onChange.
// Directional actions are routed through the same key-handling path as the keyboard
// (navLeft→←, navRight→→, navUp→↑, navDown→↓) so every focus zone behaves identically
// for keyboard and controller.
enum ControllerAction {
    case none, confirm, back
    // Fired when the button mapped to `.confirm` is RELEASED (every other action only ever
    // fires on press — this is the one exception, needed so a PLAY hold-to-confirm in progress
    // can be cancelled if the button is let go before it completes). See decisions.md #96.
    case confirmReleased
    case navLeft, navRight, navUp, navDown
    // Shoulder buttons (L1/R1) — previous/next game while the Detail page is open, mirroring
    // the on-screen edge arrows and Cmd+Left/Right on the keyboard; on any library view page
    // (carousel/grid/wall/list) they instead cycle View Mode, so browsing between layouts
    // doesn't need a controller trip up to the top bar. See decisions.md #89.
    case pageLeft, pageRight
    // Triggers (L2/R2) — cycle the source filter chips (All/CrossOver/Steam/…) on a library
    // view page. Unused elsewhere (Detail has no filter concept).
    case filterLeft, filterRight
    // Menu/Start button — open/close the pause menu, the same console convention as a PS/Xbox
    // home overlay. Full screen is a row inside the pause menu (and still ⌥⏎/⌃⌘F on keyboard).
    case pauseMenu
}

@Observable
@MainActor
final class AppState {
    var games: [Game] = []
    var selectedIndex: Int = 0
    var isLaunchingGame: Bool = false
    // Sticky DEFAULT, Preferences-only: the filter Marquee opens into. This is
    // deliberately NOT written every time `sourceFilter` changes (casual nav-bar/menu browsing
    // must never silently redefine "the default") — only `setStartupSourceFilter`, called
    // exclusively from SettingsView, persists it. See viewMode/setStartupViewMode below for the
    // matching pattern.
    private(set) var startupSourceFilter: SourceFilter = {
        SourceFilter(rawValue: UserDefaults.standard.string(forKey: "startupSourceFilter") ?? "") ?? .all
    }()

    func setStartupSourceFilter(_ filter: SourceFilter) {
        startupSourceFilter = filter
        sourceFilter = filter   // apply immediately so Preferences shows the effect of the choice
        UserDefaults.standard.set(filter.rawValue, forKey: "startupSourceFilter")
    }

    // Live, in-session filter — starts from the sticky default above but free to change via the
    // nav bar/menu without touching it, exactly like it always could before sourceFilter gained
    // persistence. (Not `lazy` — `@Observable`'s macro doesn't support lazy stored properties —
    // so this re-reads the same UserDefaults key independently at construction time instead.)
    var sourceFilter: SourceFilter = {
        SourceFilter(rawValue: UserDefaults.standard.string(forKey: "startupSourceFilter") ?? "") ?? .all
    }()
    var gamesVersion: Int = 0
    var artVersion: Int = 0
    // Bumps when a "Fix Cover Art…" override is applied — drives a live re-read of the
    // portrait art and re-fetch of the list banner in SwiftUI views (which key off it).
    var coverFixVersion: Int = 0
    // Bumps when a "Fix Banner Art…" override is applied — drives a live re-fetch of the
    // landscape list banner only (SteamHeaderImage keys off it), leaving the cover untouched.
    var bannerFixVersion: Int = 0
    var hiddenVersion: Int = 0
    var isReady: Bool = false

    // Window sizing. SwiftUI's WindowGroup sizes the window to the content's ideal size, and our
    // ContentView greedily fills all available width — so left alone SwiftUI grows the window to
    // ~screen width (it ran off the right edge of an ultrawide). To keep a fixed windowed size we
    // pin ContentView to `windowedContentSize` and use `.windowResizability(.contentSize)`, which
    // makes SwiftUI honor that size instead of fighting it (no observers, so the window stays freely
    // movable). In faux full screen the pin is lifted (`isWindowFullScreen`) so the content fills the
    // full-display frame AppDelegate sets. See MarqueeApp / ContentView.body / AppDelegate.
    var isWindowFullScreen = false
    var windowedContentSize: CGSize = AppState.defaultWindowedContentSize()

    static func defaultWindowedContentSize() -> CGSize {
        guard let screen = NSScreen.screens.first ?? NSScreen.main else {
            return CGSize(width: 1600, height: 1020)
        }
        let vf = screen.visibleFrame
        return CGSize(width: min(1600, vf.width * 0.92), height: min(1020, vf.height * 0.92))
    }

    // Sticky DEFAULT, Preferences-only — same "explicit choice only, casual browsing
    // never overwrites it" model as startupSourceFilter above. The first cut of this feature
    // persisted on every `viewMode` mutation (`didSet`), which meant simply clicking Grid/Wall/
    // List to look around — with no intent to change the default — silently redefined the
    // startup default on the very next launch.
    private(set) var startupViewMode: ViewMode = {
        ViewMode(rawValue: UserDefaults.standard.string(forKey: "startupViewMode") ?? "") ?? .carousel
    }()

    func setStartupViewMode(_ mode: ViewMode) {
        startupViewMode = mode
        viewMode = mode   // apply immediately so Preferences shows the effect of the choice
        UserDefaults.standard.set(mode.rawValue, forKey: "startupViewMode")
    }

    // Live, in-session view mode — starts from the sticky default but free to change via the nav
    // bar/menu/keyboard without touching it. MARQUEE_VIEW can still override it for testing
    // (checked in ContentView.startup, after this initial read). Not `lazy` — see sourceFilter.
    var viewMode: ViewMode = {
        ViewMode(rawValue: UserDefaults.standard.string(forKey: "startupViewMode") ?? "") ?? .carousel
    }() {
        didSet {
            // Switching view mode while the Detail page is open used to leave Detail floating
            // over the newly-selected mode underneath it — every viewMode mutation (nav bar,
            // menu bar, pause menu cycler, controller L1/R1) previously left detailTarget alone.
            // This is the one choke point all of those funnel through, so clearing it here (with
            // no animation — a mode switch should read as instant, not a Back-style fade) covers
            // every call site at once.
            if detailTarget != nil { detailTarget = nil }
        }
    }
    // Full-screen pause menu overlay (console-style) — every menu-bar action is reachable from
    // it, so a keyboardless/fullscreen "couch" setup never needs the macOS menu bar. Runtime
    // only, never persisted. Opened by Esc at the top level, a controller's Menu/Start button,
    // or the nav bar's gear button.
    var pauseMenuVisible: Bool = false
    var fixCoverTarget: Game? = nil
    var fixBannerTarget: Game? = nil    // non-nil opens the Fix Banner Art panel (list view)
    var detailTarget: Game? = nil       // non-nil shows the full-screen Detail page
    // Detail page media rail (screenshots + trailer) — shared with ContentView's unified nav
    // router so keyboard/controller can reach into DetailView's rail without DetailView owning
    // a second, disconnected key-handling path. nil focus index = the action bar is focused.
    var detailMediaItemCount: Int = 0
    var detailMediaFocusIndex: Int? = nil
    var detailMediaOverlayIndex: Int? = nil    // non-nil = enlarged screenshot/trailer showing
    // True while the open media overlay is the trailer (not a screenshot) — set by DetailView,
    // read by ContentView's unified nav router so it knows to route Left/Right/Confirm to
    // eShop-style playback controls (scrub/pause) instead of the rail's tile-to-tile navigation.
    var detailTrailerActive: Bool = false
    // Fire-once command bridge from ContentView's key/controller router to DetailView's
    // TrailerPlayer (mirrors ControllerAction) — consumed then reset to .none.
    var trailerCommand: TrailerCommand = .none

    // MARK: - PLAY hold-to-confirm (decisions.md #96)
    //
    // Jack's report: it's easy to accidentally launch a game, since the same confirm gesture
    // (Enter/Space, controller A, or a click) means different things depending on where it
    // lands — opening the modal Detail page vs. launching outright — and List's row-browsing
    // Enter shortcut launches with zero confirmation at all. Every PLAY-shaped trigger (Detail's
    // action-bar button, List's inline Play button, List's row-Enter shortcut) now funnels
    // through here instead of firing the launch immediately: the caller must hold for
    // `playHoldDuration` before `onComplete` actually runs. One shared implementation means
    // mouse (a plain DragGesture(minimumDistance: 0), released early = cancelled), keyboard
    // (key-down starts it, key-up before completion cancels), and controller (button-down/up,
    // same shape) all get identical timing and the identical visual (a progress trace around
    // the button that "completes the circuit" only at 100%).
    static let playHoldDuration: TimeInterval = 1.5
    var playHoldProgress: Double = 0
    private(set) var playHoldTargetID: UUID?
    private var playHoldTask: Task<Void, Never>?

    // Opt-out: the hold exists to stop ACCIDENTAL launches, which is a real
    // problem with a controller in a lap and a worthwhile default — but for someone who opens
    // Marquee to start a game and nothing else, a 1.5s wait on every single launch is friction
    // with no payoff. Off means a press fires immediately, through the exact same funnel, so
    // mouse/keyboard/controller stay identical to each other either way.
    var playHoldEnabled: Bool = {
        let ud = UserDefaults.standard
        return ud.object(forKey: "playHoldEnabled") == nil ? true : ud.bool(forKey: "playHoldEnabled")
    }()

    func setPlayHold(_ enabled: Bool) {
        playHoldEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "playHoldEnabled")
        if !enabled { cancelPlayHold() }
    }

    // Instant-launch mode only: the game and moment of the last launch. Key auto-repeat fires
    // keyDown over and over while the key is down, and with no hold to absorb that each repeat
    // would be a fresh launch — GameSessionManager re-foregrounds an already-running game
    // rather than de-duplicating, so the guard belongs here.
    private var lastInstantLaunch: (id: UUID, at: Date)?

    func beginPlayHold(_ game: Game, onComplete: @escaping () -> Void) {
        guard playHoldEnabled else {
            if let last = lastInstantLaunch, last.id == game.id,
               Date().timeIntervalSince(last.at) < 2.0 { return }
            lastInstantLaunch = (game.id, Date())
            onComplete()
            return
        }
        guard playHoldTargetID != game.id else { return }   // already holding this exact game
        playHoldTask?.cancel()
        let targetID = game.id
        playHoldTargetID = targetID
        playHoldProgress = 0
        playHoldTask = Task { [weak self] in
            let start = Date()
            while !Task.isCancelled {
                guard let self else { return }
                let elapsed = Date().timeIntervalSince(start)
                let progress = min(1, elapsed / AppState.playHoldDuration)
                self.playHoldProgress = progress
                if progress >= 1 { break }
                try? await Task.sleep(nanoseconds: 16_000_000)
            }
            guard !Task.isCancelled, let self, self.playHoldTargetID == targetID else { return }
            self.playHoldTargetID = nil
            self.playHoldProgress = 0
            onComplete()
        }
    }

    // Released early (mouse up, key up, controller button up) before the hold completed.
    func cancelPlayHold(_ game: Game? = nil) {
        if let game, playHoldTargetID != game.id { return }   // not the one currently held
        playHoldTask?.cancel()
        playHoldTask = nil
        playHoldTargetID = nil
        playHoldProgress = 0
    }

    var controllerAction: ControllerAction = .none
    var lastInputMethod: InputMethod = .keyboard
    // Tile under the mouse in grid/wall/list views (nil = not hovering). Drives the
    // hover highlight; cleared on any key/controller input so keyboard selection shows instead.
    var hoverIndex: Int? = nil

    // Live search — shared by all 4 view modes. searchEditing mirrors the search TextField's
    // real @FocusState (bridged down from ContentView) so the global key monitor knows when to
    // stop intercepting keystrokes and let them reach the field natively.
    var searchQuery: String = ""
    var searchEditing: Bool = false
    // Bumped whenever a separate key window (Fix Cover/Banner NSPanel, a system alert, ...)
    // closes and hands key status back to the main window. AppKit doesn't reliably restore a
    // usable first-responder state for the search TextField afterward — clicking it no longer
    // acquires real focus even though appState.searchEditing/@FocusState toggle correctly.
    // SearchSortBar applies this as the TextField's .id(), forcing SwiftUI to fully discard and
    // rebuild its underlying NSTextView/FocusState (searchQuery itself is untouched, so no typed
    // text is lost) — a clean slate sidesteps whatever AppKit-level staleness caused it.
    var searchFieldResetToken: Int = 0

    var favoritesVersion: Int = 0

    var favoriteGameIDs: Set<UUID> = {
        let stored = UserDefaults.standard.stringArray(forKey: "favoriteGameIDs") ?? []
        return Set(stored.compactMap { UUID(uuidString: $0) })
    }()

    var hasFavorites: Bool { !favoriteGameIDs.isEmpty }

    func isFavorite(_ game: Game) -> Bool { favoriteGameIDs.contains(game.id) }

    func toggleFavorite(_ game: Game) {
        // filteredGames pushes favorites to the front, so this toggle reorders the list the
        // selection lives in. Re-find the previously-selected game by id afterward so the
        // highlight stays on the same game instead of jumping to whatever slid into its old index.
        let previouslySelected = filteredGames[safe: selectedIndex]
        if favoriteGameIDs.contains(game.id) { favoriteGameIDs.remove(game.id) }
        else { favoriteGameIDs.insert(game.id) }
        UserDefaults.standard.set(favoriteGameIDs.map { $0.uuidString }, forKey: "favoriteGameIDs")
        favoritesVersion += 1
        if let previouslySelected, let newIndex = filteredGames.firstIndex(where: { $0.id == previouslySelected.id }) {
            selectedIndex = newIndex
        }
    }

    var hiddenGameIDs: Set<UUID> = {
        let stored = UserDefaults.standard.stringArray(forKey: "hiddenGameIDs") ?? []
        return Set(stored.compactMap { UUID(uuidString: $0) })
    }()

    var hasHiddenGames: Bool { !hiddenGameIDs.isEmpty }

    func hideGame(_ game: Game) {
        hiddenGameIDs.insert(game.id)
        UserDefaults.standard.set(hiddenGameIDs.map { $0.uuidString }, forKey: "hiddenGameIDs")
        hiddenVersion += 1
    }

    func unhideGame(_ game: Game) {
        hiddenGameIDs.remove(game.id)
        UserDefaults.standard.set(hiddenGameIDs.map { $0.uuidString }, forKey: "hiddenGameIDs")
        hiddenVersion += 1
    }
    enum AppTheme: String, CaseIterable {
        case outerspace = "outerspace"
        case jetBlack   = "jetBlack"
        case softGrey   = "softGrey"

        var label: String {
            switch self {
            case .outerspace: return "Space"
            case .jetBlack:   return "Black"
            case .softGrey:   return "Grey"
            }
        }
    }

    var currentTheme: AppTheme = {
        AppTheme(rawValue: UserDefaults.standard.string(forKey: "appTheme") ?? "") ?? .outerspace
    }()

    func setTheme(_ theme: AppTheme) {
        currentTheme = theme
        UserDefaults.standard.set(theme.rawValue, forKey: "appTheme")
    }

    var motionEnabled: Bool = {
        let ud = UserDefaults.standard
        return ud.object(forKey: "motionEnabled") == nil ? true : ud.bool(forKey: "motionEnabled")
    }()

    // True whenever any part of the window is actually on screen (not miniaturized, not fully
    // covered by another window, not on a different Space/display than the user is viewing) —
    // driven by AppDelegate observing NSWindow.didChangeOcclusionStateNotification. Purely a
    // runtime signal, never persisted. Exists so continuous decorative animation (MotionOverlay's
    // 30fps Canvas) can stop doing real work the instant nobody can see it, instead of burning
    // CPU indefinitely while Marquee sits minimized behind a running game — the exact "is this
    // lean in the background" case the app is meant to be good at.
    var windowVisible: Bool = true

    func setMotion(_ enabled: Bool) {
        motionEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "motionEnabled")
    }

    // Dynamic hero background — the selected game's blurred Steam hero art behind the carousel.
    var heroBackgroundEnabled: Bool = {
        let ud = UserDefaults.standard
        return ud.object(forKey: "heroBackgroundEnabled") == nil ? true : ud.bool(forKey: "heroBackgroundEnabled")
    }()

    func setHeroBackground(_ enabled: Bool) {
        heroBackgroundEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "heroBackgroundEnabled")
    }

    // Console UI sound effects — ticks on nav, confirm on launch, etc.
    var soundEffectsEnabled: Bool = {
        let ud = UserDefaults.standard
        return ud.object(forKey: "soundEffectsEnabled") == nil ? true : ud.bool(forKey: "soundEffectsEnabled")
    }()

    func setSoundEffects(_ enabled: Bool) {
        soundEffectsEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "soundEffectsEnabled")
    }

    // MARK: - Couch mode (kiosk-style setups: Mac mini under the TV, controller only)

    // Open straight into faux full screen on launch — combined with "Launch at Login" (below)
    // and macOS auto-login, Marquee boots into a console-style couch player with no keyboard
    // or mouse ever needed. Applied by AppDelegate right after the window is configured.
    var startInFullScreen: Bool = UserDefaults.standard.bool(forKey: "startInFullScreen")

    func setStartInFullScreen(_ enabled: Bool) {
        startInFullScreen = enabled
        UserDefaults.standard.set(enabled, forKey: "startInFullScreen")
    }

    // Registered as a login item via SMAppService (System Settings ▸ General ▸ Login Items shows
    // it as "Marquee"). The stored property mirrors the system's own status so the toggle
    // re-renders; setLaunchAtLogin re-reads the real status after the change in case the system
    // refused it (the OS, not us, owns this switch — it can also be flipped in System Settings).
    var launchAtLogin: Bool = LoginItem.isEnabled

    func setLaunchAtLogin(_ enabled: Bool) {
        LoginItem.setEnabled(enabled)
        launchAtLogin = LoginItem.isEnabled
    }

    // Re-read the system's answer — the user can flip this in System Settings ▸ Login Items at
    // any time, which our stored mirror can't observe. Called when the pause menu opens and when
    // the Preferences window appears, the two places the toggle is shown.
    func refreshLaunchAtLogin() {
        launchAtLogin = LoginItem.isEnabled
    }

    // MARK: - Toast (transient confirmation banner)

    // One-line feedback for actions with no other visible acknowledgement — drag & drop adds
    // in particular ("did that do anything?"). Auto-clears; a newer toast replaces the old.
    var toastMessage: String? = nil
    private var toastClearTask: Task<Void, Never>? = nil

    func showToast(_ message: String) {
        toastClearTask?.cancel()
        toastMessage = message
        toastClearTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_200_000_000)
            guard !Task.isCancelled else { return }
            self?.toastMessage = nil
        }
    }

    // MARK: - Custom library (user scan folders + individually added games)

    // Version bump so SettingsView's management lists re-render — the underlying lists live
    // in UserDefaults via CustomSource, which Observation can't see.
    var customLibraryVersion: Int = 0

    // Dropped/picked file → the right kind of custom entry. Folders become scan locations;
    // .app bundles and Windows .exes become single games. Anything else is politely refused.
    func addDroppedItem(_ url: URL) {
        let path = url.standardizedFileURL.path
        if path.hasSuffix(".app") || path.lowercased().hasSuffix(".exe") {
            addCustomGame(at: url)
        } else if (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
            addCustomScanFolder(url)
        } else {
            showToast("Drop a Mac app, a Windows .exe, or a folder of games")
        }
    }

    func addCustomGame(at url: URL) {
        let entry: CustomGameEntry
        if url.path.lowercased().hasSuffix(".exe") {
            guard let bottle = CustomSource.defaultBottle() else {
                showToast("Windows games need CrossOver — no bottles found")
                return
            }
            entry = CustomGameEntry(path: url.standardizedFileURL.path, bottle: bottle)
        } else {
            entry = CustomGameEntry(path: url.standardizedFileURL.path, bottle: nil)
        }
        guard CustomSource.addGameEntry(entry) else {
            showToast("Already in your library")
            return
        }
        customLibraryVersion += 1
        let title = url.deletingPathExtension().lastPathComponent
        showToast("Added “\(CustomSource.prettyTitle(from: title))”")
        Task {
            await loadAllGames()
            revealGame(withPath: entry.path)
        }
    }

    func addCustomScanFolder(_ url: URL) {
        guard CustomSource.addScanFolder(url) else {
            showToast("Already scanning that folder")
            return
        }
        customLibraryVersion += 1
        showToast("Scanning “\(url.lastPathComponent)” for games")
        Task { await loadAllGames() }
    }

    func removeCustomGame(_ entry: CustomGameEntry) {
        CustomSource.removeGameEntry(entry)
        customLibraryVersion += 1
        Task { await loadAllGames() }
    }

    // The path a custom-added game entry would be stored under, if this game came from one.
    // Custom entries reuse the built-in .applications/.crossOver source cases (see CustomSource.swift)
    // rather than a dedicated GameSource case, so membership has to be checked by path.
    private func customEntryPath(for game: Game) -> String? {
        switch game.source {
        case .applications(let url): return url.path
        case .crossOver(_, let exePath): return exePath.isEmpty ? nil : exePath
        default: return nil
        }
    }

    // True only for games added individually via drag-and-drop / Library ▸ Add Game… — not
    // for games found by a scan folder or any of the built-in scanners, which have no concept
    // of a single-item removal (see item 0, 2026-07-05: users need a real way to get rid of a
    // dropped non-game app like Plex, not just hide it from view).
    func isCustomLibraryGame(_ game: Game) -> Bool {
        guard let path = customEntryPath(for: game) else { return false }
        return CustomSource.gameEntries.contains { $0.path == path }
    }

    // Fully removes a custom-added game from the library (unlike hideGame, which only filters
    // it out of the visible list but leaves it in the scan + art-fetch loop).
    func removeFromLibrary(_ game: Game) {
        guard let path = customEntryPath(for: game),
              let entry = CustomSource.gameEntries.first(where: { $0.path == path })
        else { return }
        if detailTarget?.id == game.id { detailTarget = nil }
        showToast("Removed “\(game.title)” from your library")
        removeCustomGame(entry)
    }

    func removeCustomScanFolder(_ path: String) {
        CustomSource.removeScanFolder(path)
        customLibraryVersion += 1
        Task { await loadAllGames() }
    }

    // MARK: - External drives

    func setScanExternalDrives(_ enabled: Bool) {
        CustomSource.setScanExternalDrives(enabled)
        customLibraryVersion += 1
        showToast(enabled ? "Scanning external drives for games" : "External drives no longer scanned")
        Task { await loadAllGames() }
    }

    func setVolumeExcluded(_ path: String, excluded: Bool) {
        CustomSource.setVolumeExcluded(path, excluded: excluded)
        customLibraryVersion += 1
        Task { await loadAllGames() }
    }

    // Plugging a game drive in should be the whole interaction — no refresh, no Settings trip.
    // NSWorkspace's mount notifications fire on the main thread for every volume (including
    // ones we'll never scan), so the refresh is gated on the drive actually being in scope and
    // debounced: a drive with several partitions mounts them in a burst.
    private var volumeRefreshTask: Task<Void, Never>?

    func installVolumeObserver() {
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                guard let url = note.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL else { return }
                MainActor.assumeIsolated {
                    self?.volumeDidChange(url, mounted: name == NSWorkspace.didMountNotification)
                }
            }
        }
    }

    private func volumeDidChange(_ url: URL, mounted: Bool) {
        let path = url.standardizedFileURL.path
        let inScanFolders = CustomSource.scanFolders.contains {
            path == $0 || path.hasPrefix($0 + "/") || $0.hasPrefix(path + "/")
        }
        let autoScanned = CustomSource.scanExternalDrives && !CustomSource.isVolumeExcluded(path)
            && CustomSource.externalVolumes().contains { $0.standardizedFileURL.path == path }
        // An unmount can't be confirmed against the live volume list (it's already gone), so a
        // disappearing drive always refreshes when external scanning is on — its games have to
        // leave the library either way.
        guard inScanFolders || autoScanned || (!mounted && CustomSource.scanExternalDrives) else { return }

        if mounted {
            showToast("Scanning “\(CustomSource.volumeName(url))” for games")
        }
        volumeRefreshTask?.cancel()
        volumeRefreshTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled else { return }
            await self?.loadAllGames()
            self?.customLibraryVersion += 1
        }
    }

    func setCustomGameBottle(_ entry: CustomGameEntry, bottle: String) {
        var updated = entry
        updated.bottle = bottle
        CustomSource.updateGameEntry(updated)
        customLibraryVersion += 1
        Task { await loadAllGames() }
    }

    // After a hot-add, walk the selection to the new game so the user sees it land.
    // Deferred a beat: loadAllGames' gamesVersion bump makes ContentView reset selectedIndex
    // to 0 on its next render pass — selecting synchronously here would lose that race.
    private func revealGame(withPath path: String) {
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard let self else { return }
            // Visible under the current filter? Select it. Otherwise fall back to All first.
            if self.indexOfGame(withPath: path) == nil { self.sourceFilter = .all }
            if let idx = self.indexOfGame(withPath: path) { self.selectedIndex = idx }
        }
    }

    private func indexOfGame(withPath path: String) -> Int? {
        filteredGames.firstIndex { game in
            switch game.source {
            case .applications(let url):     return url.path == path
            case .crossOver(_, let exePath): return exePath == path
            default:                         return false
            }
        }
    }

    // MARK: - Add Game… / Add Folder to Scan… (Library menu)

    func promptAddGame() {
        let panel = NSOpenPanel()
        panel.title = "Add Game"
        panel.message = "Choose a Mac app or a Windows .exe to add to your library"
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        var types: [UTType] = [.applicationBundle]
        if let exe = UTType(filenameExtension: "exe") { types.append(exe) }
        panel.allowedContentTypes = types
        guard panel.runModal() == .OK else { return }
        panel.urls.forEach { addCustomGame(at: $0) }
    }

    func promptAddScanFolder() {
        let panel = NSOpenPanel()
        panel.title = "Add Folder to Scan"
        panel.message = "Marquee will look for games in this folder on every library refresh"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        panel.urls.forEach { addCustomScanFolder($0) }
    }

    var artSourcePreference: ArtSourcePreference = {
        switch UserDefaults.standard.string(forKey: "artSourcePreference") ?? "" {
        case "own":         return .own
        case "automatic":   return .automatic
        case "steamGridDB": return .steamGridDB
        default:            return .notConfigured
        }
    }()

    func saveArtPreference(_ pref: ArtSourcePreference, steamGridKey: String = "") {
        artSourcePreference = pref
        switch pref {
        case .own:         UserDefaults.standard.set("own",         forKey: "artSourcePreference")
        case .automatic:   UserDefaults.standard.set("automatic",   forKey: "artSourcePreference")
        case .steamGridDB:
            UserDefaults.standard.set("steamGridDB", forKey: "artSourcePreference")
            if !steamGridKey.isEmpty {
                UserDefaults.standard.set(steamGridKey, forKey: "steamgriddb_api_key")
            }
        case .notConfigured: break
        }
    }

    // MARK: - Resets (Settings ▸ Reset section)
    // Deliberately granular, so testing one thing (or recovering from one bad state) never
    // costs the user data they care about — play statistics in particular are only ever
    // touched by their own dedicated reset.

    // Wipes the "which art source?" choice so the first-launch welcome flow runs again —
    // immediately (the onboarding overlay is shown whenever the preference is unset), not
    // just on the next launch. A stored SteamGridDB API key is kept: re-choosing SteamGridDB
    // re-prompts for it anyway, and losing it would only make re-setup slower.
    func resetFirstLaunchSetup() {
        UserDefaults.standard.removeObject(forKey: "artSourcePreference")
        artSourcePreference = .notConfigured
    }

    // Returns appearance/behavior/startup preferences to factory defaults. Leaves alone:
    // play statistics, favorites, hidden games, art overrides, and the art-source choice.
    func resetAllSettings() {
        let ud = UserDefaults.standard
        ["appTheme", "motionEnabled", "heroBackgroundEnabled", "soundEffectsEnabled",
         "sortOption", "dateInstalledAscending", "startupViewMode", "startupSourceFilter",
         "startInFullScreen", "playHoldEnabled",
        ].forEach { ud.removeObject(forKey: $0) }
        currentTheme = .outerspace
        motionEnabled = true
        heroBackgroundEnabled = true
        soundEffectsEnabled = true
        sortOption = .aToZ
        dateInstalledAscending = false
        startupViewMode = .carousel
        startupSourceFilter = .all
        startInFullScreen = false
        playHoldEnabled = true
        // Launch at Login is deliberately NOT reset — it's a system-level login item the user
        // may have set up on purpose for a couch box; System Settings can always remove it.
    }

    // Clears play counts, last-played dates, and accumulated playtime. Kept separate (and
    // behind its own confirmation) because playtime only ever accrues through real play
    // sessions — there is no way to get it back. "Date Installed" stamps are kept so that
    // sort stays meaningful.
    func resetPlayStatistics() {
        let ud = UserDefaults.standard
        ["gamePlayCounts", "gameLastPlayed", "gamePlaytimeSeconds"].forEach { ud.removeObject(forKey: $0) }
        gamePlayCounts = [:]
        gameLastPlayed = [:]
        gamePlaytimeSeconds = [:]
    }

    // Deletes every cached cover/banner/hero image and all per-game Fix Cover/Fix Banner
    // overrides, then re-scans so art re-fetches from scratch. User-supplied art files
    // (the "My Own Files" folder) are never touched.
    func clearArtCacheAndOverrides() {
        let ud = UserDefaults.standard
        let prefixes = ["coverSearch_", "coverSteamId_", "coverDirectURL_",
                        "bannerSearch_", "bannerSteamId_", "bannerDirectURL_"]
        for key in ud.dictionaryRepresentation().keys
        where prefixes.contains(where: { key.hasPrefix($0) }) {
            ud.removeObject(forKey: key)
        }
        Task {
            await ArtCache.shared.removeAll()
            coverFixVersion += 1
            bannerFixVersion += 1
            await loadAllGames()
        }
    }

    // Order here drives the nav bar's left-to-right icon order, the pause menu's View cycler,
    // and topBarFocusIdx math (ContentView+Input) — kept as a density spectrum (immersive 3D →
    // dense table) so the icons themselves read as a progression, per Jack's ask (decisions.md
    // #97): Carousel (one game, full 3D) → Big (~2 poster rows) → Grid (~3 rows) → Wall (~4
    // rows) → List (master/detail, banner rows) → Compact List (master/detail, flat table rows).
    enum ViewMode: String, CaseIterable {
        // rainbowSlide sits right after carousel — the two are the "semi-similar" full-3D wheel
        // modes (see RainbowSlideController), both distinct from the SwiftUI grid/list family.
        case carousel, rainbowSlide, big, grid, wall, list, compactList

        var sfSymbol: String {
            switch self {
            case .carousel:     return "square.stack.3d.up.fill"
            // A literal "spinning 3D thing" glyph — distinct from Carousel's flat-stack icon,
            // reads as depth/rotation at a glance.
            case .rainbowSlide: return "rotate.3d"
            // Two large stacked rectangles — reads as "a couple of big posters," distinct from
            // Grid's evenly-divided 2×2 and Wall's dense 3×3.
            case .big:          return "rectangle.grid.1x2.fill"
            case .grid:         return "square.grid.2x2.fill"
            case .wall:         return "square.grid.3x3.fill"
            case .list:         return "list.bullet"
            // A table glyph (distinct from List's plain bullet list) for the denser, columned row
            // style — reads as "list" but visibly not the same list.
            case .compactList:  return "list.bullet.rectangle"
            }
        }

        var label: String {
            switch self {
            case .carousel:     return "Carousel"
            case .rainbowSlide: return "Rainbow Slide"
            case .big:          return "Big"
            case .grid:         return "Grid"
            case .wall:         return "Wall"
            case .list:         return "List"
            case .compactList:  return "Compact List"
            }
        }
    }

    enum SourceFilter: String, CaseIterable {
        case all, favorites, crossOver, steam, epic, gog, applications, hidden

        var label: String {
            switch self {
            case .all:          return "All"
            case .favorites:    return "Favorites"
            case .crossOver:    return "CrossOver"
            case .steam:        return "Steam"
            case .epic:         return "Epic"
            case .gog:          return "GOG"
            case .applications: return "Mac"
            case .hidden:       return "Hidden"
            }
        }
    }

    enum SortOption: String, CaseIterable {
        case aToZ, zToA, mostPlayed, playtime, lastPlayed, dateInstalled, byPlatform

        var label: String {
            switch self {
            case .aToZ:          return "A–Z"
            case .zToA:          return "Z–A"
            case .mostPlayed:    return "Most Played"
            case .playtime:      return "Playtime"
            case .lastPlayed:    return "Last Played"
            case .dateInstalled: return "Date Installed"
            case .byPlatform:    return "Platform"
            }
        }
    }

    var sortOption: SortOption = {
        SortOption(rawValue: UserDefaults.standard.string(forKey: "sortOption") ?? "") ?? .aToZ
    }()

    // Date Installed has no separate "reverse" case the way A–Z/Z–A do — clicking it again while
    // it's already the active option toggles this instead (newest-first ↔ oldest-first), the
    // same "click again to reverse" convention as a Finder list-view column header.
    var dateInstalledAscending: Bool = UserDefaults.standard.bool(forKey: "dateInstalledAscending")

    func setSortOption(_ option: SortOption) {
        if option == .dateInstalled, sortOption == .dateInstalled {
            dateInstalledAscending.toggle()
            UserDefaults.standard.set(dateInstalledAscending, forKey: "dateInstalledAscending")
            return
        }
        sortOption = option
        UserDefaults.standard.set(option.rawValue, forKey: "sortOption")
    }

    // Cycles to the next sort option, in enum declaration order — the keyboard/controller
    // equivalent of clicking the sort pill's native dropdown (which lets the mouse jump directly
    // to any option).
    func cycleSortOption() {
        let all = SortOption.allCases
        let idx = all.firstIndex(of: sortOption) ?? 0
        setSortOption(all[(idx + 1) % all.count])
    }

    // MARK: - Play tracking (Most Played / Last Played / Date Installed sorts)
    // Same "[String: T] keyed by uuidString, persisted to UserDefaults" pattern as
    // favoriteGameIDs/hiddenGameIDs.

    var gamePlayCounts: [String: Int] = {
        UserDefaults.standard.dictionary(forKey: "gamePlayCounts") as? [String: Int] ?? [:]
    }()
    var gameLastPlayed: [String: Date] = {
        UserDefaults.standard.dictionary(forKey: "gameLastPlayed") as? [String: Date] ?? [:]
    }()
    var gameDateAdded: [String: Date] = {
        UserDefaults.standard.dictionary(forKey: "gameDateAdded") as? [String: Date] ?? [:]
    }()
    // Real elapsed session time, distinct from gamePlayCounts (a launch tally) — accumulated by
    // GameSessionManager from the actual process-start/process-exit timestamps it already tracks
    // for the minimize/restore flow, not derived from play count.
    var gamePlaytimeSeconds: [String: TimeInterval] = {
        UserDefaults.standard.dictionary(forKey: "gamePlaytimeSeconds") as? [String: TimeInterval] ?? [:]
    }()

    func playCount(for game: Game) -> Int { gamePlayCounts[game.id.uuidString] ?? 0 }
    func lastPlayed(for game: Game) -> Date? { gameLastPlayed[game.id.uuidString] }
    func dateAdded(for game: Game) -> Date? { gameDateAdded[game.id.uuidString] }
    func playtime(for game: Game) -> TimeInterval { gamePlaytimeSeconds[game.id.uuidString] ?? 0 }

    // Called by GameSessionManager once a session ends, with the real elapsed time between the
    // game's process actually starting and actually exiting (not launch-to-restore, which would
    // also count the up-to-60s "waiting for it to appear" grace period).
    func addPlaytime(_ seconds: TimeInterval, to game: Game) {
        guard seconds > 0 else { return }
        let key = game.id.uuidString
        gamePlaytimeSeconds[key] = (gamePlaytimeSeconds[key] ?? 0) + seconds
        UserDefaults.standard.set(gamePlaytimeSeconds, forKey: "gamePlaytimeSeconds")
    }

    // "3h 24m" / "42m" / "Not played yet" — shared by the Detail page and anywhere else a
    // human-readable duration is needed.
    static func formattedPlaytime(_ seconds: TimeInterval) -> String {
        guard seconds > 0 else { return "Not played yet" }
        let totalMinutes = max(1, Int(seconds / 60))
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        if hours > 0 { return minutes > 0 ? "\(hours)h \(minutes)m" : "\(hours)h" }
        return "\(minutes)m"
    }

    // Called by GameSessionManager on every successful launch (all 4 PLAY paths funnel through it).
    func recordPlay(_ game: Game) {
        let key = game.id.uuidString
        gamePlayCounts[key] = (gamePlayCounts[key] ?? 0) + 1
        gameLastPlayed[key] = Date()
        UserDefaults.standard.set(gamePlayCounts, forKey: "gamePlayCounts")
        UserDefaults.standard.set(gameLastPlayed, forKey: "gameLastPlayed")
    }

    // Stamps every game's "first seen by Marquee" date once, the first time it's scanned —
    // real per-source install dates (Steam manifests, CrossOver bottle folder mtimes) are
    // inconsistent across sources, so this is the reliable proxy for "Date Installed".
    private func stampDateAddedIfNeeded(for games: [Game]) {
        var changed = false
        for game in games where gameDateAdded[game.id.uuidString] == nil {
            gameDateAdded[game.id.uuidString] = Date()
            changed = true
        }
        if changed { UserDefaults.standard.set(gameDateAdded, forKey: "gameDateAdded") }
    }

    private func platformSortKey(_ source: GameSource) -> Int {
        switch source {
        case .crossOver:    return 0
        case .steam:        return 1
        case .epic:         return 2
        case .gog:          return 3
        case .applications: return 4
        }
    }

    private func applySortOption(_ games: [Game]) -> [Game] {
        switch sortOption {
        case .aToZ:
            return games.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        case .zToA:
            return games.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedDescending }
        case .mostPlayed:
            return games.sorted {
                let (l, r) = (playCount(for: $0), playCount(for: $1))
                return l != r ? l > r : $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
            }
        case .playtime:
            return games.sorted {
                let (l, r) = (playtime(for: $0), playtime(for: $1))
                return l != r ? l > r : $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
            }
        case .lastPlayed:
            return games.sorted {
                let (l, r) = (lastPlayed(for: $0) ?? .distantPast, lastPlayed(for: $1) ?? .distantPast)
                return l != r ? l > r : $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
            }
        case .dateInstalled:
            return games.sorted {
                let (l, r) = (dateAdded(for: $0) ?? .distantPast, dateAdded(for: $1) ?? .distantPast)
                guard l != r else { return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
                return dateInstalledAscending ? l < r : l > r
            }
        case .byPlatform:
            return games.sorted {
                let (l, r) = (platformSortKey($0.source), platformSortKey($1.source))
                return l != r ? l < r : $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
            }
        }
    }

    // Favorites float to the front of every view (not just the Favorites filter) so
    // they're never more than a step or two away, while everything else keeps its
    // existing relative (sorted) order.
    private func applyFavoritesFirst(_ games: [Game]) -> [Game] {
        guard hasFavorites else { return games }
        return games.filter { favoriteGameIDs.contains($0.id) } + games.filter { !favoriteGameIDs.contains($0.id) }
    }

    // MARK: - Search

    // Public wrapper used by views (search-match glow) and filteredGames (ranking).
    // nil = no match at all (query char missing, and no source-name substring hit either).
    func matchScore(for game: Game) -> Double? {
        if let titleScore = Self.titleMatchScore(query: searchQuery, title: game.title) {
            return titleScore
        }
        let q = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return nil }
        return game.sourceBadgeTitle.lowercased().contains(q) ? 50 : nil
    }

    // Exact > prefix > word-boundary prefix > substring > fuzzy in-order subsequence.
    private static func titleMatchScore(query: String, title: String) -> Double? {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return nil }
        let t = title.lowercased()

        if t == q { return 1000 }
        if t.hasPrefix(q) { return 900 - Double(t.count - q.count) }
        let words = t.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        if words.contains(where: { $0.hasPrefix(q) }) { return 700 - Double(t.count) }
        if t.contains(q) { return 500 - Double(t.count) }

        // Fuzzy fallback: every query char must appear in order (not necessarily contiguous).
        // Tighter, earlier matches score higher; missing a char = no match at all.
        var searchFrom = t.startIndex
        var firstMatchPos: Int?
        var lastMatchPos = 0
        for qc in q {
            guard let found = t[searchFrom...].firstIndex(of: qc) else { return nil }
            let pos = t.distance(from: t.startIndex, to: found)
            if firstMatchPos == nil { firstMatchPos = pos }
            lastMatchPos = pos
            searchFrom = t.index(after: found)
        }
        let span = lastMatchPos - (firstMatchPos ?? 0)
        return 200 - Double(span) - Double(firstMatchPos ?? 0) * 0.5
    }

    var filteredGames: [Game] {
        let base: [Game]
        if sourceFilter == .hidden {
            base = games.filter { hiddenGameIDs.contains($0.id) }
        } else {
            let visible = games.filter { !hiddenGameIDs.contains($0.id) }
            if sourceFilter == .favorites {
                base = visible.filter { favoriteGameIDs.contains($0.id) }
            } else if sourceFilter == .all {
                base = visible
            } else {
                base = visible.filter { game in
                    switch (sourceFilter, game.source) {
                    case (.crossOver,    .crossOver):    return true
                    case (.steam,        .steam):        return true
                    case (.epic,         .epic):         return true
                    case (.gog,          .gog):          return true
                    case (.applications, .applications): return true
                    default: return false
                    }
                }
            }
        }

        let sorted = applySortOption(base)

        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return applyFavoritesFirst(sorted) }

        // Search ranking overrides favorites-first: matches (best score first), then the
        // non-matching leftovers keep the existing sorted + favorites-first order — favorited
        // games "slide to second fiddle" behind an actual search match, same as any other game.
        let scored = sorted.compactMap { game in matchScore(for: game).map { (game, $0) } }
                            .sorted { $0.1 > $1.1 }
                            .map { $0.0 }
        let scoredIDs = Set(scored.map(\.id))
        let leftover = applyFavoritesFirst(sorted.filter { !scoredIDs.contains($0.id) })
        return scored + leftover
    }

    // Sets one game's localArtPath via a full `games = ` reassignment rather than an in-place
    // `games[idx].field = x` subscript mutation. The two look equivalent but aren't: Grid/Wall/
    // List read art through the COMPUTED `filteredGames` (which reads `games` internally), and
    // the Observation framework's change tracking for a computed property's dependents does not
    // reliably fire on a nested subscript `_modify` into an array element the way it reliably
    // does on a whole-property `set` — confirmed live (art was cached correctly on disk, but a
    // grid/wall launched directly into as the startup view never painted it; switching to another
    // view mode and back — forcing a fresh mount — showed it instantly). `artVersion` itself
    // (a plain, non-array Int) was never affected, which is why the carousel's imperative
    // `applyArtToCarousel()` path masked this for years — it never depended on `games` being
    // observed, only on `artVersion`, which always fired correctly.
    private func setLocalArtPath(_ url: URL, forGameId id: UUID) {
        guard let idx = games.firstIndex(where: { $0.id == id }) else { return }
        var updated = games
        updated[idx].localArtPath = url
        games = updated
    }

    func loadAllGames() async {
        async let crossOver = Task.detached { CrossOverSource.scan() }.value
        async let steam     = Task.detached { SteamSource.scan() }.value
        async let epic      = Task.detached { EpicSource.scan() }.value
        async let gog       = Task.detached { GOGSource.scan() }.value
        async let apps      = Task.detached { ApplicationsSource.scan() }.value
        async let custom    = Task.detached { CustomSource.scan() }.value
        var all = await crossOver + steam + epic + gog + apps + custom
        // Custom entries last + unique-by-id: a user scan folder that overlaps a built-in
        // scanner's territory (say, /Applications itself) yields the identical stable UUID
        // for the same bundle, so the built-in's richer result wins and nothing double-shows.
        var seenIDs = Set<UUID>()
        all = all.filter { seenIDs.insert($0.id).inserted }
        all.sort { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }

        // Test hook: pretend every scanner came back empty, to exercise the empty-library
        // state on a machine that has real games installed.
        if ProcessInfo.processInfo.environment["MARQUEE_SIMULATE_EMPTY"] != nil { all = [] }

        // An empty scan means an empty library — EmptyLibraryView tells the user where Marquee
        // looked and how to refresh. (The old behavior fell back to the dev placeholder titles,
        // which read as ten fake games a brand-new user doesn't own and can't launch.
        // MARQUEE_PLACEHOLDERS=1 restores them for screenshots/dev work.)
        if all.isEmpty && ProcessInfo.processInfo.environment["MARQUEE_PLACEHOLDERS"] != nil {
            loadPlaceholders()
        } else {
            games = all
        }
        stampDateAddedIfNeeded(for: games)
        gamesVersion += 1

        // Fetch art serially in background; signals isReady when the loop finishes.
        // Hidden games are skipped outright — a hidden non-game app (e.g. Plex, dropped in
        // just to be couch-launchable) shouldn't keep getting matched against a game art
        // database every refresh just because it's still in the library.
        Task {
            for game in self.games where !self.hiddenGameIDs.contains(game.id) {
                if let artURL = await ArtFetcher.shared.fetch(for: game) {
                    self.setLocalArtPath(artURL, forGameId: game.id)
                    self.artVersion += 1
                }
            }
            self.isReady = true
        }
    }

    // Fired when connectivity returns (NetworkMonitor.onReconnect, wired in MarqueeApp):
    // re-fetches art for every game that has nothing in the permanent art cache — which is
    // exactly the set that started up offline (ArtFetcher deliberately doesn't cache its
    // offline bundled-icon fallback, so those games are indistinguishable from never-fetched
    // ones by this criterion; user-placed and fixed art all live in the cache and are skipped).
    private var artRetryInProgress = false

    func retryMissingArt() async {
        guard !artRetryInProgress else { return }
        artRetryInProgress = true
        defer { artRetryInProgress = false }
        for game in games where !hiddenGameIDs.contains(game.id) {
            guard await ArtCache.shared.cachedURL(for: game.id) == nil else { continue }
            if let artURL = await ArtFetcher.shared.fetch(for: game) {
                setLocalArtPath(artURL, forGameId: game.id)
                artVersion += 1
            }
        }
    }

    // Re-fetch art for one game using an override search term or Steam App ID.
    // Clears the cached art first so ArtFetcher hits the network.
    // Calls completion(true) on success, completion(false) on failure.
    func refetchCover(for game: Game, searchTerm: String? = nil, steamAppId: Int? = nil,
                      directURL: URL? = nil, completion: @escaping (Bool) -> Void = { _ in }) {
        print("[Marquee] refetchCover: \(game.title) [\(game.id.uuidString.prefix(8))]")
        let key = game.id.uuidString
        if let id = steamAppId, id > 0 {
            UserDefaults.standard.set(id, forKey: "coverSteamId_\(key)")
            UserDefaults.standard.removeObject(forKey: "coverDirectURL_\(key)")
        }
        if let term = searchTerm, !term.isEmpty {
            UserDefaults.standard.set(term, forKey: "coverSearch_\(key)")
        }
        if let url = directURL {
            UserDefaults.standard.set(url.absoluteString, forKey: "coverDirectURL_\(key)")
            UserDefaults.standard.removeObject(forKey: "coverSteamId_\(key)")
        }

        Task {
            await ArtCache.shared.remove(for: game.id)
            if let url = await ArtFetcher.shared.fetch(for: game) {
                self.setLocalArtPath(url, forGameId: game.id)
                self.artVersion += 1
                self.coverFixVersion += 1   // refresh grid/wall/list art + list banner
                completion(true)
            } else {
                print("[Marquee] refetch failed: \(game.title)")
                completion(false)
            }
        }
    }

    // Re-fetch the landscape list banner for one game using a banner-specific override
    // (search term / Steam App ID / direct image URL). Clears only the cached header so the
    // portrait cover is left intact. Calls completion(true/false).
    func refetchBanner(for game: Game, searchTerm: String? = nil, steamAppId: Int? = nil,
                       directURL: URL? = nil, completion: @escaping (Bool) -> Void = { _ in }) {
        print("[Marquee] refetchBanner: \(game.title) [\(game.id.uuidString.prefix(8))]")
        let key = game.id.uuidString
        if let id = steamAppId, id > 0 {
            UserDefaults.standard.set(id, forKey: "bannerSteamId_\(key)")
            UserDefaults.standard.removeObject(forKey: "bannerDirectURL_\(key)")
        }
        if let term = searchTerm, !term.isEmpty {
            UserDefaults.standard.set(term, forKey: "bannerSearch_\(key)")
        }
        if let url = directURL {
            UserDefaults.standard.set(url.absoluteString, forKey: "bannerDirectURL_\(key)")
            UserDefaults.standard.removeObject(forKey: "bannerSteamId_\(key)")
        }

        Task {
            await ArtCache.shared.removeHeader(for: game.id)
            if let url = await ArtFetcher.shared.fetchHeader(for: game),
               NSImage(contentsOf: url) != nil {
                self.bannerFixVersion += 1   // re-fetch the list banner (SteamHeaderImage)
                completion(true)
            } else {
                print("[Marquee] refetchBanner failed: \(game.title)")
                completion(false)
            }
        }
    }

    // User-uploaded cover image (Fix Cover "Choose File…") — skips network fetch entirely,
    // just caches the picked file directly. Clears any prior override so the upload wins.
    func applyCustomCover(for game: Game, fileURL: URL, completion: @escaping (Bool) -> Void = { _ in }) {
        let key = game.id.uuidString
        UserDefaults.standard.removeObject(forKey: "coverSteamId_\(key)")
        UserDefaults.standard.removeObject(forKey: "coverSearch_\(key)")
        UserDefaults.standard.removeObject(forKey: "coverDirectURL_\(key)")
        Task {
            await ArtCache.shared.remove(for: game.id)
            if let url = await ArtFetcher.shared.cacheLocalFile(at: fileURL, gameId: game.id) {
                self.setLocalArtPath(url, forGameId: game.id)
                self.artVersion += 1
                self.coverFixVersion += 1
                completion(true)
            } else {
                completion(false)
            }
        }
    }

    // User-uploaded banner image (Fix Banner "Choose File…") — same idea, header-only.
    func applyCustomBanner(for game: Game, fileURL: URL, completion: @escaping (Bool) -> Void = { _ in }) {
        let key = game.id.uuidString
        UserDefaults.standard.removeObject(forKey: "bannerSteamId_\(key)")
        UserDefaults.standard.removeObject(forKey: "bannerSearch_\(key)")
        UserDefaults.standard.removeObject(forKey: "bannerDirectURL_\(key)")
        Task {
            await ArtCache.shared.removeHeader(for: game.id)
            if await ArtFetcher.shared.cacheLocalHeaderFile(at: fileURL, gameId: game.id) != nil {
                self.bannerFixVersion += 1
                completion(true)
            } else {
                completion(false)
            }
        }
    }

    func loadPlaceholders() {
        let titles = [
            "Hi-Fi RUSH", "Subnautica 2", "Solarpunk",
            "Everybody's Golf: Hot Shots", "MOUSE P.I. For Hire",
            "Hades II", "Hollow Knight: Silksong", "Celeste",
            "Disco Elysium", "Outer Wilds"
        ]
        games = titles.enumerated().map { i, title in
            let sources: [GameSource] = [
                .crossOver(bottleName: "DX12-Win11", exePath: "/drive_c/GAMES/\(title)/game.exe"),
                .steam(appId: 1000000 + i),
                .epic(appName: title.lowercased().replacingOccurrences(of: " ", with: ""), catalogItemId: UUID().uuidString),
                .applications(bundleURL: URL(fileURLWithPath: "/Applications/\(title).app"))
            ]
            return Game(title: title, source: sources[i % 4])
        }
    }
}
