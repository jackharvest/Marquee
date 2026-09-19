import SwiftUI

// Preferences window — opened via the standard macOS "Settings…"/"Preferences…" app-menu
// item + ⌘, (wired for free by wrapping this in a `Settings` scene in MarqueeApp, see there).
// Everything here is "sticky": each control writes straight through to the same AppState/
// MusicPlayerController setters the rest of the app already uses, which are the ones that persist
// to UserDefaults — so there's no separate "save" step, and no separate source of truth to drift
// out of sync with the nav bar / bottom controls / music widget.
//
// EXCEPT Startup View/Filter, which are two-tier on purpose: `AppState.viewMode`/`sourceFilter`
// are live, in-session state that casually browsing the nav bar changes all the time, same as
// always — this panel's "Startup View"/"Startup Filter" rows read/write the SEPARATE
// `startupViewMode`/`startupSourceFilter` (only ever set via `setStartupViewMode`/
// `setStartupSourceFilter`, called from here and nowhere else), so idle curiosity in Grid or List
// mid-session can never silently redefine what Marquee opens into next time.
//
// Every row leads with a small "silhouette" glyph — reusing icons already
// established elsewhere in the app (view-mode icons, the motion/backdrop toggle glyphs, the
// music widget's own iconography) so a setting's *category* reads at a glance before the label
// text does.
struct SettingsView: View {
    @Environment(AppState.self) private var appState
    @Environment(MusicPlayerController.self) private var musicPlayer
    @Environment(SoundEffects.self) private var soundEffects

    // Which reset row is asking "are you sure?" — drives one shared confirmation dialog.
    @State private var pendingReset: ResetKind? = nil

    private static let accent = Color(red: 0.76, green: 0.46, blue: 1.0)

    // Favorites/Hidden are situational (only meaningful once the user has some), not a genuine
    // "always start here" library-wide default — left off this picker on purpose.
    private static let startupFilterChoices: [AppState.SourceFilter] =
        [.all, .crossOver, .steam, .epic, .gog, .applications]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header
                libracySection
                customLibrarySection
                appearanceSection
                musicSection
                behaviorSection
                controllerSection
                couchModeSection
                updatesSection
                resetSection
            }
            .padding(22)
        }
        .frame(width: 480, height: 660)
        .background(Color(red: 0.07, green: 0.04, blue: 0.14))
        .foregroundStyle(.white)
        // Launch at Login lives in System Settings' hands too — re-read it on every open.
        .onAppear { appState.refreshLaunchAtLogin() }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "gearshape.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Self.accent)
            VStack(alignment: .leading, spacing: 1) {
                Text("Preferences")
                    .font(.system(size: 17, weight: .bold))
                Text("These stick — Marquee remembers them between launches.")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.4))
            }
            Spacer()
        }
        .padding(.bottom, 4)
    }

    // MARK: - Library section (view / filter / sort)

    private var libracySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionLabel("Library")

            PreferenceRow(icon: appState.startupViewMode.sfSymbol, iconColor: Self.accent,
                          title: "Startup View", subtitle: "Which layout Marquee opens into") {
                HStack(spacing: 6) {
                    ForEach(AppState.ViewMode.allCases, id: \.self) { mode in
                        Button { appState.setStartupViewMode(mode) } label: {
                            VStack(spacing: 3) {
                                Image(systemName: mode.sfSymbol)
                                    .font(.system(size: 14, weight: .semibold))
                                Text(mode.label)
                                    .font(.system(size: 9, weight: .medium))
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .foregroundStyle(appState.startupViewMode == mode ? .white : .white.opacity(0.4))
                            .background(appState.startupViewMode == mode ? Self.accent.opacity(0.35) : Color.white.opacity(0.05))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            PreferenceRow(icon: "line.3.horizontal.decrease.circle.fill", iconColor: .cyan,
                          title: "Startup Filter", subtitle: "Which games are visible when Marquee opens") {
                HStack(spacing: 6) {
                    ForEach(Self.startupFilterChoices, id: \.self) { filter in
                        Button(filter.label) { appState.setStartupSourceFilter(filter) }
                            .buttonStyle(FilterChipStyle(isActive: appState.startupSourceFilter == filter))
                    }
                }
            }

            PreferenceRow(icon: "arrow.up.arrow.down", iconColor: .orange,
                          title: "Default Sort", subtitle: "How the library orders on a fresh launch") {
                Menu {
                    ForEach(AppState.SortOption.allCases, id: \.self) { option in
                        Button {
                            appState.setSortOption(option)
                        } label: {
                            if appState.sortOption == option {
                                Label(option.label, systemImage: "checkmark")
                            } else {
                                Text(option.label)
                            }
                        }
                    }
                } label: {
                    menuLabel(appState.sortOption.label)
                }
                .menuStyle(.borderlessButton)
            }
        }
    }

    // MARK: - Custom Library section (user scan folders + individually added games)

    private var customLibrarySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionLabel("Custom Library")

            PreferenceRow(icon: "folder.badge.plus", iconColor: .teal,
                          title: "Scan Folders",
                          subtitle: "Extra places Marquee looks for games — network shares, external drives") {
                // customLibraryVersion lives on AppState purely so this control re-renders —
                // the lists themselves live in CustomSource/UserDefaults, invisible to Observation.
                let _ = appState.customLibraryVersion
                VStack(alignment: .leading, spacing: 6) {
                    if CustomSource.scanFolders.isEmpty {
                        Text("None yet — you can also drop a folder anywhere on the Marquee window")
                            .font(.system(size: 11))
                            .foregroundStyle(.white.opacity(0.4))
                    } else {
                        ForEach(CustomSource.scanFolders, id: \.self) { path in
                            HStack(spacing: 8) {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text((path as NSString).lastPathComponent)
                                        .font(.system(size: 12, weight: .medium))
                                    Text(path)
                                        .font(.system(size: 9))
                                        .foregroundStyle(.white.opacity(0.55))
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }
                                Spacer()
                                Button {
                                    appState.removeCustomScanFolder(path)
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundStyle(.white.opacity(0.35))
                                }
                                .buttonStyle(.plain)
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 6)
                            .background(RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(0.04)))
                        }
                    }
                    addButton("Add Folder…") { appState.promptAddScanFolder() }
                }
            }

            PreferenceRow(icon: "externaldrive.fill", iconColor: .orange,
                          title: "External Drives",
                          subtitle: "Plug a drive in and its games show up — no folder to pick") {
                let _ = appState.customLibraryVersion
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Text("Scan every drive that's plugged in")
                            .font(.system(size: 11))
                            .foregroundStyle(.white.opacity(0.55))
                        Spacer()
                        Toggle("", isOn: Binding(get: { CustomSource.scanExternalDrives },
                                                  set: { appState.setScanExternalDrives($0) }))
                            .toggleStyle(.switch)
                            .controlSize(.small)
                            .tint(Self.accent)
                            .labelsHidden()
                    }

                    // What's actually mounted right now, so "is my drive being scanned?" is a
                    // question the panel answers instead of one the user has to test by
                    // refreshing. Each one can be waved off individually — a Time Machine or
                    // media disk has no games and shouldn't be walked on every refresh.
                    if CustomSource.scanExternalDrives {
                        let volumes = CustomSource.externalVolumes()
                        if volumes.isEmpty {
                            Text("No external drives connected right now")
                                .font(.system(size: 11))
                                .foregroundStyle(.white.opacity(0.4))
                        } else {
                            ForEach(volumes, id: \.path) { volume in
                                let excluded = CustomSource.isVolumeExcluded(volume.path)
                                HStack(spacing: 8) {
                                    Image(systemName: "externaldrive")
                                        .font(.system(size: 12))
                                        .foregroundStyle(.white.opacity(excluded ? 0.3 : 0.75))
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(CustomSource.volumeName(volume))
                                            .font(.system(size: 12, weight: .medium))
                                            .foregroundStyle(.white.opacity(excluded ? 0.45 : 1))
                                        Text(driveStatus(volume.path, excluded: excluded))
                                            .font(.system(size: 9))
                                            .foregroundStyle(.white.opacity(0.5))
                                    }
                                    Spacer()
                                    Toggle("", isOn: Binding(
                                        get: { !CustomSource.isVolumeExcluded(volume.path) },
                                        set: { appState.setVolumeExcluded(volume.path, excluded: !$0) }))
                                        .toggleStyle(.switch)
                                        .controlSize(.mini)
                                        .tint(Self.accent)
                                        .labelsHidden()
                                }
                                .padding(.horizontal, 8)
                                .padding(.vertical, 6)
                                .background(RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(0.04)))
                            }
                        }
                    }
                }
            }

            PreferenceRow(icon: "plus.app.fill", iconColor: .indigo,
                          title: "Added Games",
                          subtitle: "Individually added apps and Windows exes — drag & drop works too") {
                let _ = appState.customLibraryVersion
                VStack(alignment: .leading, spacing: 6) {
                    if CustomSource.gameEntries.isEmpty {
                        Text("None yet — you can also drop a game anywhere on the Marquee window")
                            .font(.system(size: 11))
                            .foregroundStyle(.white.opacity(0.4))
                    } else {
                        ForEach(CustomSource.gameEntries) { entry in
                            HStack(spacing: 8) {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(entry.url.deletingPathExtension().lastPathComponent)
                                        .font(.system(size: 12, weight: .medium))
                                    Text(entry.path)
                                        .font(.system(size: 9))
                                        .foregroundStyle(.white.opacity(0.55))
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }
                                Spacer()
                                // Bottle picker only earns its keep once there's an actual
                                // choice to make — a single-bottle setup has nothing to pick.
                                if entry.isExe, CrossOverSource.availableBottles().count > 1 {
                                    Menu {
                                        ForEach(CrossOverSource.availableBottles(), id: \.self) { bottle in
                                            Button(bottle) { appState.setCustomGameBottle(entry, bottle: bottle) }
                                        }
                                    } label: {
                                        Text(entry.bottle ?? "—")
                                            .font(.system(size: 10, weight: .medium))
                                            .foregroundStyle(.white.opacity(0.75))
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 3)
                                            .background(RoundedRectangle(cornerRadius: 5).fill(Color.white.opacity(0.08)))
                                    }
                                    .menuStyle(.borderlessButton)
                                    .fixedSize()
                                }
                                Button {
                                    appState.removeCustomGame(entry)
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundStyle(.white.opacity(0.35))
                                }
                                .buttonStyle(.plain)
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 6)
                            .background(RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(0.04)))
                        }
                    }
                    addButton("Add Game…") { appState.promptAddGame() }
                }
            }
        }
    }

    // A drive's one-line status: what the last scan of it found, which is the thing that tells
    // the user whether leaving it switched on is buying them anything.
    private func driveStatus(_ path: String, excluded: Bool) -> String {
        if excluded { return "Skipped" }
        switch CustomSource.volumeScanResult(path) {
        case .none:    return "Scanned for games"
        case .some(0): return "No games found here"
        case .some(1): return "1 game found"
        case .some(let n): return "\(n) games found"
        }
    }

    // Small pill button shared by both Custom Library rows.
    private func addButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .buttonStyle(.plain)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.white.opacity(0.85))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.07)))
    }

    // MARK: - Appearance section

    private var appearanceSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionLabel("Appearance")

            PreferenceRow(icon: "paintpalette.fill", iconColor: .pink,
                          title: "Accent Color", subtitle: "The app's background theme") {
                HStack(spacing: 18) {
                    ForEach(AppState.AppTheme.allCases, id: \.self) { theme in
                        Button { appState.setTheme(theme) } label: {
                            VStack(spacing: 6) {
                                Circle()
                                    .fill(theme.swatch)
                                    .frame(width: 22, height: 22)
                                    .overlay(Circle().strokeBorder(Color.white.opacity(0.38), lineWidth: 1))
                                    .overlay(
                                        Circle()
                                            .strokeBorder(appState.currentTheme == theme ? Color.white : .clear, lineWidth: 2)
                                            .padding(-3)
                                    )
                                Text(theme.label)
                                    .font(.system(size: 10))
                                    .foregroundStyle(.white.opacity(0.6))
                            }
                        }
                        .buttonStyle(.plain)
                    }
                    Spacer()
                }
            }

            ToggleRow(icon: "photo.fill", iconColor: .yellow,
                      title: "Game Backdrop", subtitle: "Blurred hero art behind the library",
                      isOn: Binding(get: { appState.heroBackgroundEnabled },
                                     set: { appState.setHeroBackground($0) }))

            ToggleRow(icon: "waveform", iconColor: .mint,
                      title: "Background Motion", subtitle: "Drifting waves, wisps, and particles",
                      isOn: Binding(get: { appState.motionEnabled },
                                     set: { appState.setMotion($0) }))
        }
    }

    // MARK: - Music section

    private var musicSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionLabel("Music")

            ToggleRow(icon: "music.note", iconColor: .purple,
                      title: "Music Player",
                      subtitle: "The player in the bottom-left corner, and its background music",
                      isOn: Binding(get: { musicPlayer.isEnabled },
                                     set: { musicPlayer.setEnabled($0) }))

            // Volume and startup song only mean something while there's a player to hear —
            // with it switched off they'd be controls for a feature that isn't running.
            if musicPlayer.isEnabled {
            PreferenceRow(icon: volumeGlyph, iconColor: .green,
                          title: "Volume", subtitle: "Background music level") {
                HStack(spacing: 10) {
                    Slider(value: Binding(get: { Double(musicPlayer.volume) },
                                           set: { musicPlayer.setVolume(Float($0)) }), in: 0...1)
                    Text("\(Int(musicPlayer.volume * 100))%")
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.55))
                        .frame(width: 38, alignment: .trailing)
                }
            }

            PreferenceRow(icon: musicPlayer.startupTrackIndex == nil ? "shuffle" : "music.note",
                          iconColor: .purple,
                          title: "Startup Song", subtitle: "Random uses each track's shuffle weight") {
                Menu {
                    Button {
                        musicPlayer.setStartupTrack(nil)
                    } label: {
                        if musicPlayer.startupTrackIndex == nil {
                            Label("Random", systemImage: "checkmark")
                        } else {
                            Text("Random")
                        }
                    }
                    Divider()
                    ForEach(musicPlayer.trackNames.indices, id: \.self) { i in
                        Button {
                            musicPlayer.setStartupTrack(i)
                        } label: {
                            if musicPlayer.startupTrackIndex == i {
                                Label(musicPlayer.trackNames[i], systemImage: "checkmark")
                            } else {
                                Text(musicPlayer.trackNames[i])
                            }
                        }
                    }
                } label: {
                    menuLabel(musicPlayer.startupTrackIndex.flatMap { musicPlayer.trackNames[safe: $0] } ?? "Random")
                }
                .menuStyle(.borderlessButton)
            }
            }
        }
    }

    // MARK: - Behavior section

    private var behaviorSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionLabel("Behavior")

            ToggleRow(icon: appState.playHoldEnabled ? "timer" : "play.circle.fill",
                      iconColor: .green,
                      title: "Hold PLAY to Launch",
                      subtitle: appState.playHoldEnabled
                          ? "Hold for a moment to start a game — guards against a stray button press"
                          : "A single click, key, or button press starts the game right away",
                      isOn: Binding(get: { appState.playHoldEnabled },
                                     set: { appState.setPlayHold($0) }))

            ToggleRow(icon: appState.soundEffectsEnabled ? "speaker.wave.2.fill" : "speaker.slash.fill",
                      iconColor: .blue,
                      title: "Sound Effects", subtitle: "Nav ticks, confirm, and back chimes",
                      isOn: Binding(get: { appState.soundEffectsEnabled },
                                     set: {
                                         appState.setSoundEffects($0)
                                         // The synth engine keeps its own flag — sync it here the
                                         // same way the Appearance menu's toggle does, or the
                                         // change wouldn't take effect until the next launch.
                                         soundEffects.enabled = $0
                                     }))
        }
    }

    // MARK: - Controller section

    private var controllerSection: some View {
        let store = ControllerMappingStore.shared
        return VStack(alignment: .leading, spacing: 10) {
            sectionLabel("Controller")

            PreferenceRow(icon: "gamecontroller.fill", iconColor: .blue,
                          title: "Button Layout", subtitle: "Which physical button confirms and which cancels") {
                HStack(spacing: 6) {
                    ForEach(ControllerMappingStore.Preset.allCases, id: \.self) { preset in
                        Button(preset.label) { store.applyPreset(preset) }
                            .buttonStyle(FilterChipStyle(isActive: store.activePreset == preset))
                    }
                }
            }

            PreferenceRow(icon: "arrow.triangle.swap", iconColor: .orange,
                          title: "Custom Bindings",
                          subtitle: "Rebinding a button that's already in use swaps the two — every action always keeps a button") {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(MappableAction.allCases, id: \.self) { action in
                        HStack(spacing: 8) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(action.label)
                                    .font(.system(size: 12, weight: .semibold))
                                Text(action.subtitle)
                                    .font(.system(size: 10))
                                    .foregroundStyle(.white.opacity(0.4))
                            }
                            Spacer()
                            if store.captureTarget == action {
                                Text("Press any button…")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundStyle(Self.accent)
                                Button("Cancel") { store.endCapture() }
                                    .buttonStyle(.plain)
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(.white.opacity(0.6))
                            } else {
                                Text(store.button(for: action).label)
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundStyle(.white.opacity(0.85))
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 3)
                                    .background(RoundedRectangle(cornerRadius: 5).fill(Color.white.opacity(0.12)))
                                Button("Rebind") { store.beginCapture(for: action) }
                                    .buttonStyle(.plain)
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(Self.accent)
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Couch Mode section (kiosk-style setups: Mac mini under the TV)

    // The full recipe (with macOS auto-login, controller pairing, and TV output) lives in the
    // README's "Couch Mode" section — these two switches are the app-side half of it. Both are
    // also rows in the in-app pause menu, so they're settable from the couch itself.
    private var couchModeSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionLabel("Couch Mode")

            ToggleRow(icon: "power", iconColor: .green,
                      title: "Launch at Login",
                      subtitle: "Registers Marquee as a login item (System Settings shows it too)",
                      isOn: Binding(get: { appState.launchAtLogin },
                                     set: { appState.setLaunchAtLogin($0) }))

            ToggleRow(icon: "sunrise.fill", iconColor: .orange,
                      title: "Start in Full Screen",
                      subtitle: "Open straight into full screen — no keyboard needed",
                      isOn: Binding(get: { appState.startInFullScreen },
                                     set: { appState.setStartInFullScreen($0) }))
        }
    }

    // MARK: - Reset section

    // What each reset touches (and, just as importantly, what it doesn't) lives in the
    // matching AppState.reset* methods. Play statistics get the scariest wording because
    // playtime only accrues through real play sessions — it can't be recovered.
    private enum ResetKind: String, Identifiable, CaseIterable {
        case firstLaunch, allSettings, artCache, playStats
        var id: String { rawValue }

        var title: String {
            switch self {
            case .firstLaunch: return "Reset First-Launch Setup"
            case .allSettings: return "Reset All Settings"
            case .artCache:    return "Clear Art Cache & Custom Covers"
            case .playStats:   return "Reset Play Statistics"
            }
        }
        var subtitle: String {
            switch self {
            case .firstLaunch: return "Run the welcome flow again (art source choice)"
            case .allSettings: return "Appearance, startup, and behavior back to defaults"
            case .artCache:    return "Deletes downloaded art and Fix Cover overrides, then re-fetches"
            case .playStats:   return "Play counts, last played, and playtime — cannot be undone"
            }
        }
        var icon: String {
            switch self {
            case .firstLaunch: return "sparkles"
            case .allSettings: return "arrow.counterclockwise"
            case .artCache:    return "photo.on.rectangle.angled"
            case .playStats:   return "clock.badge.xmark"
            }
        }
        var confirmMessage: String {
            switch self {
            case .firstLaunch:
                return "The welcome flow will appear again so you can re-pick how cover art is found. Nothing else is touched."
            case .allSettings:
                return "Appearance, startup, behavior, and music settings return to defaults. Your games, favorites, playtime, and custom covers are kept."
            case .artCache:
                return "All downloaded art and Fix Cover/Banner overrides are deleted, then everything re-fetches fresh. Your own image files are not touched."
            case .playStats:
                return "Play counts, last-played dates, and total playtime for every game will be permanently erased. This cannot be undone."
            }
        }
    }

    // MARK: - Updates section

    private var updatesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionLabel("Updates")

            HStack(spacing: 10) {
                iconBadge("arrow.triangle.2.circlepath", Self.accent)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Marquee v\(AppUpdater.shared.currentVersion)")
                        .font(.system(size: 13, weight: .semibold))
                    Text("Checked automatically on launch")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.4))
                }
                Spacer()
                Button("Check Now") {
                    Task { await AppUpdater.shared.checkForUpdates(userInitiated: true, appState: appState) }
                }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(0.85))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(0.07)))
            }
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.05)))
        }
    }

    private var resetSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionLabel("Reset")

            ForEach(ResetKind.allCases) { kind in
                HStack(spacing: 10) {
                    iconBadge(kind.icon, kind == .playStats ? .red : .gray)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(kind.title)
                            .font(.system(size: 13, weight: .semibold))
                        Text(kind.subtitle)
                            .font(.system(size: 11))
                            .foregroundStyle(.white.opacity(0.4))
                    }
                    Spacer()
                    Button("Reset…") { pendingReset = kind }
                        .buttonStyle(.plain)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(kind == .playStats ? .red : .white.opacity(0.85))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(0.07)))
                }
                .padding(14)
                .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.05)))
            }
        }
        .confirmationDialog(
            pendingReset?.title ?? "",
            isPresented: Binding(get: { pendingReset != nil },
                                 set: { if !$0 { pendingReset = nil } }),
            titleVisibility: .visible
        ) {
            Button(pendingReset == .playStats ? "Erase Play Statistics" : "Reset",
                   role: .destructive) {
                if let kind = pendingReset { perform(kind) }
                pendingReset = nil
            }
            Button("Cancel", role: .cancel) { pendingReset = nil }
        } message: {
            Text(pendingReset?.confirmMessage ?? "")
        }
    }

    private func perform(_ kind: ResetKind) {
        switch kind {
        case .firstLaunch:
            appState.resetFirstLaunchSetup()
            // The welcome flow lives in the main window — bring it forward so the effect
            // is visible immediately instead of hidden behind this Preferences window.
            NSApp.windows.first(where: { !($0 is NSPanel) && $0.isVisible })?
                .makeKeyAndOrderFront(nil)
        case .allSettings:
            appState.resetAllSettings()
            soundEffects.enabled = true
            musicPlayer.setVolume(0.3)
            musicPlayer.setStartupTrack(nil)
        case .artCache:
            appState.clearArtCacheAndOverrides()
        case .playStats:
            appState.resetPlayStatistics()
        }
    }

    // MARK: - Shared bits

    private var volumeGlyph: String {
        switch musicPlayer.volume {
        case ..<0.01:  return "speaker.slash.fill"
        case ..<0.34:  return "speaker.wave.1.fill"
        case ..<0.67:  return "speaker.wave.2.fill"
        default:       return "speaker.wave.3.fill"
        }
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(.white.opacity(0.32))
            .padding(.top, 6)
    }

    private func menuLabel(_ text: String) -> some View {
        HStack {
            Text(text)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.85))
            Spacer()
            Image(systemName: "chevron.up.chevron.down")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.white.opacity(0.4))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(0.07)))
    }
}

// MARK: - Row templates

// A titled row fronted by a small "silhouette" glyph badge, with a caller-supplied control
// underneath — used for anything with more than a binary choice (view mode, filter, sort,
// theme, volume, startup song).
private struct PreferenceRow<Control: View>: View {
    let icon: String
    let iconColor: Color
    let title: String
    let subtitle: String
    @ViewBuilder let control: () -> Control

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                iconBadge(icon, iconColor)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.4))
                }
                Spacer()
            }
            control()
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.05)))
    }
}

// Same glyph-badge header as PreferenceRow, but for a plain on/off — the native switch sits
// inline on the header row instead of a control block below, since it needs no extra room.
private struct ToggleRow: View {
    let icon: String
    let iconColor: Color
    let title: String
    let subtitle: String
    @Binding var isOn: Bool

    var body: some View {
        HStack(spacing: 10) {
            iconBadge(icon, iconColor)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.4))
            }
            Spacer()
            Toggle("", isOn: $isOn)
                .toggleStyle(.switch)
                .tint(Color(red: 0.76, green: 0.46, blue: 1.0))
                .labelsHidden()
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.05)))
    }
}

// Shared by both row templates — a small rounded-square glyph badge that reads as "this
// setting's category" before the label text does.
private func iconBadge(_ icon: String, _ color: Color) -> some View {
    ZStack {
        RoundedRectangle(cornerRadius: 9)
            .fill(color.opacity(0.18))
            .frame(width: 30, height: 30)
        Image(systemName: icon)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(color)
    }
}
