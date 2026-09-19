import SwiftUI
import AppKit

// Console-style pause menu — a full-viewport, PS3 XMB-style overlay that mirrors every menu-bar
// action, so the entire app is operable in full screen with only a controller (Mac-mini-under-
// the-TV setups never see the macOS menu bar). Opened by Esc at the top level, a controller's
// Menu/Start button, or the nav bar's gear button; Esc/B/Menu closes it.
//
// Two-level focus, matching the XMB reference (Jack's screenshots): a horizontal strip of
// category icons across the middle of the screen, and — once you press Down into one — a
// vertical list of that category's rows opens below it. Left/Right changes CATEGORY only while
// focus sits on the icon strip (`rowIdx == nil`); once you've dropped into a row, Left/Right
// instead adjusts that row's value (a cycler's chevrons), matching "vertically to deep dive,
// horizontally to enter new categories" — see decisions.md #90.
//
// Keyboard/controller input is routed here by ContentView's unified nav router
// (handlePauseMenuKey in ContentView+PauseMenu.swift) — this view only renders state and
// forwards mouse clicks through the same onActivate/onAdjust closures the key router uses,
// so both input paths fire identical actions.
//
// Perpendicular-cross mechanics (v0.26.0, from Jack's own detailed XMB walkthrough): both tracks
// are centered on ONE fixed focal x in the left-center quadrant (`focalXFraction`), not the
// screen's dead center — the category strip and the row list beneath it share that anchor so
// they read as one cross, not two independently-centered panels. Selection never "moves a
// cursor" — pressing a direction slides the relevant track past a fixed focal window instead
// (the row list's own conveyor: the focused row is pinned at a fixed slot via `.offset`, the
// same mechanism the category strip already used). Both tracks fade neighbors continuously with
// distance from focus (`ghostOpacity`) rather than a flat selected/unselected toggle, so items
// visibly recede the further they sit from the intersection. See decisions.md #93.
//
// Two corrections from a follow-up round (v0.27.0), both from Jack catching the reference more
// precisely than the first pass did:
//
// 1. The row list is really ONE continuous vertical column that the horizontal category strip
// sits in front of, not a list confined below it. `itemAndCategoryTrack` overlays both tracks in
// a single shared coordinate space (y = 0 at the category strip's own vertical center); each
// row's position is `rowBaseY + (idx - rowIdx) * rowSlotHeight`, so rows already scrolled past
// (idx < rowIdx) land at a NEGATIVE y — above the category strip, exactly as described — while
// rows still ahead stay below it. The category strip renders on top (later in the ZStack), so a
// row passing through it during the spring animation visibly slides behind it, not over it.
//
// 2. Left/Right ALWAYS shifts category, even with a row focused — adjusting a row's value is a
// separate, deliberately-entered sub-mode (`armed`, driven by `pauseMenuRowArmed` in ContentView)
// entered by pressing confirm on an adjustable row, which is the only time Left/Right steps that
// row's value instead of the category. This removes the old ambiguity where Left/Right's meaning
// silently depended on whether a row happened to be focused. See decisions.md #94.
//
// Clean "portal" above the strip (v0.28.0): v0.27.0's single `rowBaseY + (idx - rowIdx) *
// rowSlotHeight` formula was one continuous stride in both directions, which put a row only 1-2
// steps behind focus at a y still INSIDE the strip's own vertical span — it read as text piled up
// behind/under the icons rather than cleanly clearing above them (Jack's live report, reference:
// the PS3 Settings screenshot, where already-passed rows sit in clean air above the icon row, not
// drifting through it). `rowY` is now two zones mirrored around the strip: rows still ahead of
// focus step down from `rowBaseY` exactly as before; rows already passed step UP from `-rowBaseY`
// instead of continuing the same downward stride past center, so the first passed row portals
// straight to the far side of the strip's `categoryStripHalfHeight + rowStripGap` clearance.

// Top-level per naming convention (nesting breaks cross-file type lookup).
enum PauseMenuItem: Equatable {
    case resume
    case fullScreen          // toggle faux full screen
    case moveDisplay         // cycle to the next connected display (only if >1)
    case viewMode            // cycler
    case sourceFilter        // cycler
    case sortOption          // cycler
    case refreshLibrary
    case fixCover            // selected game
    case hideGame            // selected game
    case theme               // cycler
    case backdrop            // toggle
    case motion              // toggle
    case soundEffects        // toggle
    case musicVolume         // cycler (±5%)
    case launchAtLogin       // toggle
    case startInFullScreen   // toggle
    case controllerLayout    // cycler (Standard/Nintendo button preset)
    case allSettings
    case checkForUpdates
    case about
    case quit

    // Left/Right (or the chevrons) adjust these; the rest are Enter/click actions.
    var isAdjustable: Bool {
        switch self {
        case .viewMode, .sourceFilter, .sortOption, .theme, .musicVolume,
             .controllerLayout: return true
        default: return false
        }
    }

    var icon: String {
        switch self {
        case .resume:            return "play.fill"
        case .fullScreen:        return "arrow.up.left.and.arrow.down.right"
        case .moveDisplay:       return "tv"
        case .viewMode:          return "square.stack.3d.up.fill"
        case .sourceFilter:      return "line.3.horizontal.decrease.circle.fill"
        case .sortOption:        return "arrow.up.arrow.down"
        case .refreshLibrary:    return "arrow.clockwise"
        case .fixCover:          return "photo.badge.magnifyingglass"
        case .hideGame:          return "eye.slash.fill"
        case .theme:             return "paintpalette.fill"
        case .backdrop:          return "photo.fill"
        case .motion:            return "waveform"
        case .soundEffects:      return "speaker.wave.2.fill"
        case .musicVolume:       return "music.note"
        case .launchAtLogin:     return "power"
        case .startInFullScreen: return "sunrise.fill"
        case .controllerLayout:  return "gamecontroller.fill"
        case .allSettings:       return "gearshape.fill"
        case .checkForUpdates:   return "arrow.triangle.2.circlepath"
        case .about:             return "info.circle.fill"
        case .quit:              return "xmark.circle.fill"
        }
    }
}

// The horizontal top-level XMB categories. Each owns a contiguous slice of PauseMenuItem rows —
// context-dependent ones (second display, per-game actions) drop out when they can't apply.
// ContentView's key router and this view MUST both derive rows from here so focus indices
// always line up.
enum PauseMenuCategory: Int, CaseIterable {
    case resume, display, library, appearance, audio, couchMode, controller, system

    var label: String {
        switch self {
        case .resume:     return "Resume"
        case .display:    return "Display"
        case .library:    return "Library"
        case .appearance: return "Appearance"
        case .audio:      return "Audio"
        case .couchMode:  return "Couch Mode"
        case .controller: return "Controller"
        case .system:     return "Marquee"
        }
    }

    var icon: String {
        switch self {
        case .resume:     return "play.fill"
        case .display:    return "rectangle.on.rectangle"
        case .library:    return "square.grid.2x2.fill"
        case .appearance: return "paintpalette.fill"
        case .audio:      return "speaker.wave.2.fill"
        case .couchMode:  return "sofa.fill"
        case .controller: return "gamecontroller.fill"
        case .system:     return "gearshape.fill"
        }
    }

    @MainActor
    func items(appState: AppState) -> [PauseMenuItem] {
        switch self {
        case .resume:
            return [.resume]
        case .display:
            var items: [PauseMenuItem] = [.fullScreen]
            if NSScreen.screens.count > 1 { items.append(.moveDisplay) }
            items += [.viewMode, .sourceFilter, .sortOption]
            return items
        case .library:
            var items: [PauseMenuItem] = [.refreshLibrary]
            if appState.filteredGames[safe: appState.selectedIndex] != nil {
                items += [.fixCover, .hideGame]
            }
            return items
        case .appearance:
            return [.theme, .backdrop, .motion]
        case .audio:
            // No music widget (Preferences ▸ Music) means no music volume to set — the row
            // would adjust something the user has switched off entirely.
            return MusicPlayerController.enabledPreference ? [.soundEffects, .musicVolume]
                                                           : [.soundEffects]
        case .couchMode:
            return [.launchAtLogin, .startInFullScreen]
        case .controller:
            return [.controllerLayout]
        case .system:
            return [.allSettings, .checkForUpdates, .about, .quit]
        }
    }
}

struct PauseMenuView: View {
    @Environment(AppState.self) private var appState
    @Environment(MusicPlayerController.self) private var musicPlayer

    let categoryIdx: Int
    let rowIdx: Int?
    // True while the focused row's cycler value is armed for Left/Right adjustment — the only
    // state in which Left/Right doesn't shift category (decisions.md #94).
    let armed: Bool
    let onDismiss: () -> Void
    let onSelectCategory: (Int) -> Void
    let onActivate: (Int, PauseMenuItem) -> Void
    let onAdjust: (PauseMenuItem, Int) -> Void

    private static let accent = Color(red: 0.76, green: 0.46, blue: 1.0)
    private let iconSlotWidth: CGFloat = 130
    // The one fixed point both tracks pass through — Jack's reference XMB anchors its focal
    // window in the left-center quadrant, not dead screen-center; the category strip centers its
    // selected icon here, and the row list hangs directly beneath that same x so the two tracks
    // read as one perpendicular cross rather than two independently-centered panels.
    private static let focalXFraction: CGFloat = 0.30
    // Nominal per-row step distance (padding + text + inter-row spacing) used to slide the row
    // list so the FOCUSED row is the thing that stays put — everything else moves past it, same
    // "cursor glued in place, world conveys past it" rule the category strip already followed.
    private static let rowSlotHeight: CGFloat = 48
    // Half the category strip's own rendered height (118pt, see categoryRow's `.frame(height:)`)
    // — the boundary a row must clear before it counts as "above" or "below" the strip.
    private static let categoryStripHalfHeight: CGFloat = 59
    // Clean air between the strip's edge and the nearest row on either side. Below this gap, rows
    // step down in normal `rowSlotHeight` increments (the still-to-visit queue); above it, rows
    // that have already been scrolled past land here directly. Without this gap the old single
    // `rowBaseY + (idx - rowIdx) * rowSlotHeight` formula put a row 1-2 steps back AT y ≈ ±27,
    // i.e. still inside the strip's own ±59 vertical span — it rendered overlapping/behind the
    // icons instead of "portaling" cleanly above them, reading as text piled on top of itself.
    private static let rowStripGap: CGFloat = 26
    // The focused row's fixed y, measured from the shared track's center (y = 0, where the
    // category strip itself sits) — chosen to equal the un-drilled preview list's own first-row
    // position so pressing Down the first time causes zero visual jump.
    private static let rowBaseY: CGFloat = categoryStripHalfHeight + rowStripGap
    // Tall enough for several rows to peek on both sides of the category strip before ghosting/
    // clipping hides them — this is the shared vertical space both tracks occupy together.
    private static let trackHeight: CGFloat = 400

    private var categories: [PauseMenuCategory] { PauseMenuCategory.allCases }
    private var currentCategory: PauseMenuCategory { categories[safe: categoryIdx] ?? .resume }
    private var currentItems: [PauseMenuItem] { currentCategory.items(appState: appState) }

    var body: some View {
        GeometryReader { geo in
            let focalX = geo.size.width * Self.focalXFraction
            ZStack {
                // Dim + blur everything behind; a click outside either strip resumes.
                Rectangle()
                    .fill(.ultraThinMaterial)
                    .overlay(Color.black.opacity(0.45))
                    .ignoresSafeArea()
                    .onTapGesture { onDismiss() }

                VStack(spacing: 0) {
                    header
                    Spacer(minLength: 0)
                    itemAndCategoryTrack(focalX: focalX)
                    Spacer(minLength: 0)
                    footer
                }
            }
        }
    }

    // Continuous falloff shared by both tracks — the "Ghosting" rule: items don't just toggle
    // between selected/unselected, they fade progressively with distance from the focal point
    // until they disappear, rather than reading as two flat opacity states.
    private static func ghostOpacity(_ distance: Int) -> Double {
        switch distance {
        case 0: return 1.0
        case 1: return 0.55
        case 2: return 0.28
        case 3: return 0.12
        default: return 0.0
        }
    }

    // MARK: - Header / footer (float directly over the dimmed backdrop, no panel)

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "pause.circle.fill")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(Self.accent)
            Text("Paused")
                .font(.system(size: 20, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
            Spacer()
            if let game = appState.filteredGames[safe: appState.selectedIndex] {
                Text(game.title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white.opacity(0.45))
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 34)
        .padding(.top, 30)
    }

    private var footer: some View {
        // Controller hints read the LIVE mapping — after a Nintendo-style swap the select
        // hint must say B, or the menu itself would be teaching the wrong button.
        let mapping = ControllerMappingStore.shared
        let atCategoryLevel = rowIdx == nil
        let focusedItem = rowIdx.flatMap { currentItems[safe: $0] }
        let controller = appState.lastInputMethod == .controller
        return HStack(spacing: 18) {
            if armed {
                // The one state where Left/Right does NOT change category — it's stepping the
                // armed row's value instead, so that's the only hint shown for it here.
                hintPair(controller ? "◀ ▶" : "← →", "adjust")
                hintPair(controller ? mapping.button(for: .confirm).label : "⏎", "done")
            } else {
                // Left/Right ALWAYS changes category outside the armed sub-mode — even with a
                // row focused — so this hint is unconditional (decisions.md #94).
                hintPair(controller ? "L1/R1" : "← →", "change category")
                if atCategoryLevel {
                    hintPair(controller ? "▼" : "↓", "open")
                } else {
                    hintPair(controller ? "▲ ▼" : "↑ ↓", "navigate")
                }
                hintPair(controller ? mapping.button(for: .confirm).label : "⏎",
                         focusedItem?.isAdjustable == true ? "adjust" : "select")
            }
            hintPair(controller
                     ? "\(mapping.button(for: .back).label) / \(mapping.button(for: .pauseMenu).label)"
                     : "esc", atCategoryLevel ? "resume" : "back")
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 22)
        .background(
            LinearGradient(colors: [.clear, Color.black.opacity(0.35)], startPoint: .top, endPoint: .bottom)
        )
    }

    private func hintPair(_ key: String, _ label: String) -> some View {
        HStack(spacing: 6) {
            Text(key)
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundStyle(.white.opacity(0.8))
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(RoundedRectangle(cornerRadius: 5).fill(Color.white.opacity(0.12)))
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.45))
        }
    }

    // MARK: - Category strip (horizontal, always centers the selected icon — XMB's own feel)

    private func categoryRow(focalX: CGFloat) -> some View {
        HStack(spacing: 0) {
            ForEach(Array(categories.enumerated()), id: \.element) { idx, category in
                categoryIcon(category, distance: abs(idx - categoryIdx))
                    .frame(width: iconSlotWidth)
                    .contentShape(Rectangle())
                    .onTapGesture { onSelectCategory(idx) }
            }
        }
        // Claim the full available width (left-aligned) BEFORE offsetting/clipping — otherwise
        // this HStack's own intrinsic width (8 × iconSlotWidth) is all the outer VStack sees, so
        // the VStack's default center alignment parks the whole strip mid-screen regardless of
        // what `focalX` says, and `.clipped()` below would clip against that too-small box
        // instead of the real window edges (defeating the "off-screen icons vanish" viewport).
        .frame(maxWidth: .infinity, alignment: .leading)
        // Centers the SELECTED icon on the shared focal x, not the middle of the screen — the
        // conveyor-belt rule: pressing Right slides this whole track left, pulling the next
        // category into the fixed focal window rather than moving a cursor across the strip.
        .offset(x: focalX - iconSlotWidth / 2 - CGFloat(categoryIdx) * iconSlotWidth)
        .animation(.spring(response: 0.32, dampingFraction: 0.78), value: categoryIdx)
        .frame(height: 118)
        .clipped()
        // While a row's value is armed, category-shifting is paused (decisions.md #94) — dim the
        // whole strip to read as inert rather than leaving it looking fully interactive.
        .opacity(armed ? 0.45 : 1.0)
        .animation(.easeOut(duration: 0.15), value: armed)
    }

    private func categoryIcon(_ category: PauseMenuCategory, distance: Int) -> some View {
        let selected = distance == 0
        // Once a row is focused (drilled in), the icon dims a touch and loses its selection ring
        // — still clearly "the active category," but visually secondary to the open row list,
        // same idea as Detail's actionBarActive gating (decisions.md #47's "one outline, one place").
        let drilledIn = selected && rowIdx != nil
        return VStack(spacing: 10) {
            Image(systemName: category.icon)
                .font(.system(size: selected ? 28 : 20, weight: .semibold))
                .foregroundStyle(selected ? .white : .white.opacity(0.32))
                .frame(width: selected ? 68 : 52, height: selected ? 68 : 52)
                .background(
                    Circle().fill(selected ? Self.accent.opacity(drilledIn ? 0.22 : 0.34) : Color.white.opacity(0.05))
                )
                .overlay(
                    Circle().strokeBorder(
                        selected && !drilledIn ? Color.white.opacity(0.9) : .clear,
                        lineWidth: 2.5
                    )
                )
                .shadow(color: .black.opacity(selected ? 0.4 : 0), radius: 10, y: 4)

            Text(category.label.uppercased())
                .font(.system(size: 11, weight: .bold))
                .tracking(0.5)
                .foregroundStyle(.white.opacity(0.85))
                .opacity(selected ? 1 : 0)
        }
        // Continuous falloff by distance from the focal window, not a flat selected/unselected
        // toggle — an icon two slots away reads as clearly further from focus than its immediate
        // neighbor, matching the reference's "fade into transparency until they disappear."
        .scaleEffect(selected ? 1.0 : max(0.55, 0.85 - CGFloat(distance - 1) * 0.08))
        .opacity(Self.ghostOpacity(distance))
        .animation(.spring(response: 0.3, dampingFraction: 0.75), value: selected)
        .animation(.easeOut(duration: 0.15), value: drilledIn)
    }

    // MARK: - Track (shared vertical space: the row list is one continuous column that the
    // horizontal category strip sits in front of, not a panel confined below it)

    // Row `idx`'s y, relative to the track's shared center (0 = the category strip's own
    // vertical middle). Two zones, not one continuous conveyor: rows still ahead of focus
    // (idx >= rowIdx, including the focused row itself) step DOWN from `rowBaseY` in normal
    // `rowSlotHeight` increments, same as before. Rows already scrolled past (idx < rowIdx)
    // instead step UP from `-rowBaseY` — mirrored around the strip, not a continuation of the
    // same downward stride — so a row that just passed focus "portals" straight to clean air
    // above the strip's ±categoryStripHalfHeight span instead of drifting through the middle of
    // it. With no row focused yet (`rowIdx == nil`, previewing) this reduces to the same
    // `rowBaseY + idx * rowSlotHeight` downward stack it always was, since every idx counts as
    // "still ahead" of the implicit focus at 0.
    private func rowY(_ idx: Int) -> CGFloat {
        let focus = rowIdx ?? 0
        if idx < focus {
            let stepsBack = focus - idx  // >= 1
            return -Self.rowBaseY - CGFloat(stepsBack - 1) * Self.rowSlotHeight
        }
        return Self.rowBaseY + CGFloat(idx - focus) * Self.rowSlotHeight
    }

    private func itemAndCategoryTrack(focalX: CGFloat) -> some View {
        ZStack {
            // Rows first (bottom layer) so the category strip visually sits in front of them —
            // a row sliding from below focus to above it passes BEHIND the strip mid-transition,
            // the same "something in the way" feel Jack described.
            ZStack {
                ForEach(Array(currentItems.enumerated()), id: \.element) { idx, item in
                    row(item, distance: rowIdx.map { abs($0 - idx) }, focused: rowIdx == idx,
                        armed: armed && rowIdx == idx)
                        .frame(width: 560, alignment: .leading)
                        .offset(y: rowY(idx))
                        .onTapGesture { onActivate(idx, item) }
                }
            }
            .animation(.spring(response: 0.32, dampingFraction: 0.78), value: rowIdx)
            // The list is always present (so mouse users can click straight into a row without
            // pressing Down first) but reads as a preview — no ring, dimmer text — until rowIdx
            // is actually set, so focus visibly "lives" on the icon strip until you drop into it.
            .opacity(rowIdx == nil ? 0.55 : 1.0)
            .animation(.easeOut(duration: 0.15), value: rowIdx == nil)
            .id(categoryIdx)   // fresh transition when the category changes, not a diffed reorder
            .transition(.opacity)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, max(24, focalX - iconSlotWidth / 2))

            categoryRow(focalX: focalX)
        }
        .frame(height: Self.trackHeight)
        .clipped()
    }

    private func row(_ item: PauseMenuItem, distance: Int?, focused: Bool, armed: Bool) -> some View {
        HStack(spacing: 12) {
            Image(systemName: item.icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(iconColor(item))
                .frame(width: 24)

            Text(title(item))
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(item == .quit ? Color(red: 1.0, green: 0.55, blue: 0.55) : .white)
                .lineLimit(1)

            Spacer()

            if item.isAdjustable {
                adjusterValue(item, focused: focused, armed: armed)
            } else if let state = toggleState(item) {
                Text(state ? "On" : "Off")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(state ? Self.accent : .white.opacity(0.35))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(focused ? (armed ? Self.accent.opacity(0.16) : Color.white.opacity(0.12)) : .clear)
        )
        .overlay(
            // Armed rows get the accent ring instead of white — a distinct color, not just a
            // state change on the same ring, so it's unmistakable that Left/Right now adjusts
            // THIS row's value instead of shifting category (decisions.md #94).
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(focused ? (armed ? Self.accent : Color.white.opacity(0.85)) : .clear,
                              lineWidth: armed ? 2.5 : 1.5)
        )
        .contentShape(Rectangle())
        .hoverHighlight(scale: 1.0, brighten: 0.08)
        // Same continuous ghosting as the category strip, scoped to the vertical track: rows
        // further from the focused one fade progressively rather than just being un-highlighted.
        // `distance == nil` (not drilled into a row yet) reads at full strength — the outer
        // itemList opacity already carries the whole-list dimming for that preview state.
        .opacity(distance.map { Self.ghostOpacity($0) } ?? 1.0)
        .scaleEffect((distance ?? 0) == 0 ? 1.0 : 0.96, anchor: .leading)
        .animation(.easeOut(duration: 0.18), value: distance)
    }

    // Cycler rows: ‹ value › — chevrons are real click targets for the mouse.
    private func adjusterValue(_ item: PauseMenuItem, focused: Bool, armed: Bool) -> some View {
        HStack(spacing: 7) {
            chevron("chevron.left")  { onAdjust(item, -1) }
            Text(value(item))
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(0.85))
                .frame(minWidth: 92)
                .multilineTextAlignment(.center)
                .padding(.vertical, 3)
                .background(
                    Capsule().fill(armed ? Self.accent.opacity(0.3) : .clear)
                )
            chevron("chevron.right") { onAdjust(item, +1) }
        }
        .opacity(focused ? 1.0 : 0.75)
    }

    private func chevron(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.white.opacity(0.6))
                .frame(width: 20, height: 20)
                .background(Circle().fill(Color.white.opacity(0.08)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .hoverHighlight()
    }

    // MARK: - Row content helpers

    private func title(_ item: PauseMenuItem) -> String {
        switch item {
        case .resume:            return "Resume"
        case .fullScreen:        return "Full Screen"
        case .moveDisplay:       return "Move to Next Display"
        case .viewMode:          return "View"
        case .sourceFilter:      return "Filter"
        case .sortOption:        return "Sort"
        case .refreshLibrary:    return "Refresh Library"
        case .fixCover:          return "Fix Cover Art…"
        case .hideGame:          return "Hide Selected Game"
        case .theme:             return "Accent Color"
        case .backdrop:          return "Game Backdrop"
        case .motion:            return "Background Motion"
        case .soundEffects:      return "Sound Effects"
        case .musicVolume:       return "Music Volume"
        case .launchAtLogin:     return "Launch at Login"
        case .startInFullScreen: return "Start in Full Screen"
        case .controllerLayout:  return "Button Layout"
        case .allSettings:       return "All Settings…"
        case .checkForUpdates:   return "Check for Updates…"
        case .about:             return "About Marquee"
        case .quit:              return "Quit Marquee"
        }
    }

    private func value(_ item: PauseMenuItem) -> String {
        switch item {
        case .viewMode:     return appState.viewMode.label
        case .sourceFilter: return appState.sourceFilter.label
        case .sortOption:   return appState.sortOption.label
        case .theme:        return appState.currentTheme.label
        case .musicVolume:  return "\(Int(musicPlayer.volume * 100))%"
        // "Custom" = hand-rebound in Settings beyond either preset; cycling from it snaps
        // back onto the presets (see pauseMenuAdjust).
        case .controllerLayout:
            return ControllerMappingStore.shared.activePreset?.label ?? "Custom"
        default:            return ""
        }
    }

    private func toggleState(_ item: PauseMenuItem) -> Bool? {
        switch item {
        case .fullScreen:        return appState.isWindowFullScreen
        case .backdrop:          return appState.heroBackgroundEnabled
        case .motion:            return appState.motionEnabled
        case .soundEffects:      return appState.soundEffectsEnabled
        case .launchAtLogin:     return appState.launchAtLogin
        case .startInFullScreen: return appState.startInFullScreen
        default:                 return nil
        }
    }

    private func iconColor(_ item: PauseMenuItem) -> Color {
        switch item {
        case .resume:                 return Self.accent
        case .quit:                   return Color(red: 1.0, green: 0.55, blue: 0.55)
        case .launchAtLogin, .startInFullScreen: return .green
        default:                      return .white.opacity(0.6)
        }
    }
}
