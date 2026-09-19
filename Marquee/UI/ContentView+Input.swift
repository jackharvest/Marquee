import SwiftUI
import AppKit

// Unified keyboard + controller navigation. Everything funnels into handleNavKey with a macOS
// keyCode, whether it came from a real key press (routeKeyDown, installed as an NSEvent monitor)
// or a controller button (ControllerAction mapped to key codes in ContentView.body) — so both
// input methods behave identically in every focus zone.

// UI focus zones — drives keyboard/controller navigation between screen regions.
// Top-level per naming convention: nesting in a struct confuses cross-file type lookup.
enum UIFocusZone: Equatable {
    case carousel, topBar, bottomControls, musicPlayer
    // The search + sort pill row. Sits between topBar and carousel/content in the vertical
    // zone chain (topBar ↔ searchSort ↔ carousel/content ↔ bottomControls) in every view mode.
    case searchSort
    // List view only — the inline Play/Favorite/Hide row in the right-hand detail panel.
    // Entered from `.carousel` (the row list) via Right, so it can't show a focus ring in two
    // places at once (the row list's own highlight stays, since it means "which game", not
    // "which button" — see the Detail page action-bar/media-rail fix for the same principle).
    case listActions
}

extension ContentView {

    // MARK: - Key routing

    // The key-down monitor's whole routing body, pulled out of the trailing closure passed to
    // NSEvent.addLocalMonitorForEvents — with everything inline there, the compiler bundled the
    // closure's full body into that generic call's overload resolution and blew its type-check
    // time budget. A plain method is checked independently, no matter how many branches it has.
    func routeKeyDown(_ event: NSEvent) -> NSEvent? {
        // Cmd+F — jump straight to the search field from any page/view (matches the ⌘F hint
        // shown in the pill when it's empty and unfocused). Checked before the searchEditing
        // passthrough below so it also works as a no-op-but-stay-focused shortcut while already
        // typing, instead of literally inserting an "f". Closes the Detail page first since the
        // global SearchSortBar is hidden while it's open (see rootStack).
        if event.modifierFlags.contains(.command), event.keyCode == 3,
           appState.fixCoverTarget == nil, appState.fixBannerTarget == nil,
           appState.artSourcePreference != .notConfigured {
            let hadDetail = appState.detailTarget != nil
            if hadDetail { appState.detailTarget = nil }
            // onChange(of: appState.detailTarget) reactively resets uiFocus = .carousel
            // on any detailTarget -> nil transition — including this one. Setting uiFocus/
            // searchEditing synchronously here would just lose that race and get clobbered a
            // moment later. Deferring lets our request run AFTER that reset has already landed,
            // so it's the one that sticks — and by then SearchSortBar (hidden while Detail was
            // open) has actually appeared, giving @FocusState something real to claim.
            if hadDetail {
                DispatchQueue.main.async {
                    uiFocus = .searchSort
                    searchSortFocusIdx = 0
                    appState.searchEditing = true
                }
            } else {
                uiFocus = .searchSort
                searchSortFocusIdx = 0
                appState.searchEditing = true
            }
            return nil
        }

        // The search field has real first-responder focus — get out of the way so normal
        // typing/backspace/cursor-arrows reach it instead of being eaten by the WASD remap / nav
        // router below. Esc is the one key we still intercept, to blur back to zone-nav mode on
        // the search pill (see SearchSortBar/searchEditing).
        if appState.searchEditing {
            return handleSearchEditingPassthrough(event)
        }

        // Context-menu key — the PC "Menu/Application" key (keyCode 110) or Shift+F10
        // (keyCode 109) — opens the right-click menu for the SELECTED game, so the
        // whole UI (incl. Fix Cover/Banner) is reachable by keyboard alone.
        if event.keyCode == 110
            || (event.keyCode == 109 && event.modifierFlags.contains(.shift)) {
            appState.lastInputMethod = .keyboard
            appState.hoverIndex = nil
            presentSelectionContextMenu()
            return nil
        }

        // ALT+ENTER — toggle full screen, the convention nearly every game uses.
        // Handled globally (not zone-specific), same action as ⌃⌘F/the top-bar button.
        if event.modifierFlags.contains(.option), event.keyCode == 36 || event.keyCode == 76 {
            session.appDelegate?.toggleFullScreen()
            return nil
        }

        // Cmd+Left/Right — step to the previous/next game while the Detail page is open
        // (mirrors the on-screen edge arrows / controller shoulder buttons). Requires the
        // modifier so it doesn't collide with Detail's own Left/Right (action-button nav).
        if appState.detailTarget != nil, event.modifierFlags.contains(.command),
           event.keyCode == 123 || event.keyCode == 124 {
            navigateDetail(event.keyCode == 123 ? -1 : 1)
            return nil
        }

        // Remap WASD → arrow key codes so gamer navigation works everywhere.
        // keyCode: A=0, S=1, D=2, W=13
        var kc = event.keyCode
        switch kc {
        case 0:  kc = 123   // A → left
        case 1:  kc = 125   // S → down
        case 2:  kc = 124   // D → right
        case 13: kc = 126   // W → up
        default: break
        }

        // Any key press → keyboard mode; mouse hover highlight yields to keyboard.
        appState.lastInputMethod = .keyboard
        appState.hoverIndex = nil
        let handled = handleNavKey(kc)
        updateCarouselRing()
        if handled { return nil }
        return event
    }

    // While the search TextField has real first-responder focus, only Esc is ours (blur back to
    // zone-nav mode) — everything else passes through untouched so typing/backspace/cursor-arrows
    // reach the field natively instead of being eaten by the WASD remap / nav router.
    private func handleSearchEditingPassthrough(_ event: NSEvent) -> NSEvent? {
        if event.keyCode == 53 {
            appState.searchEditing = false
            return nil
        }
        return event
    }

    // MARK: - Zone navigation

    // kc is a macOS keyCode (arrows 123/124/125/126, enter 36, space 49, esc 53).
    // Returns true if consumed. Both the NSEvent key monitor and the controller route here,
    // so keyboard and controller behave identically in every focus zone.
    func handleNavKey(_ kc: UInt16) -> Bool {
        // Pause menu owns ALL input while it's up — checked before everything else (including
        // the Detail page, since the controller's Menu button can raise it over Detail too).
        if appState.pauseMenuVisible { return handlePauseMenuKey(kc) }

        // Detail page — navigate between 4 action buttons, or (when present) the media rail
        // of screenshots/trailer above them. Up from the action bar enters the rail (if it has
        // any items); Down leaves it back to the action bar; Esc backs out one level at a time
        // (overlay → rail → action bar → close), matching every other focus zone's convention.
        if let game = appState.detailTarget {
            // eShop-style trailer playback — while the media overlay is open AND it's the
            // trailer (not a screenshot), Left/Right/Confirm/Back take over completely instead
            // of the rail's tile-to-tile navigation (which would otherwise silently move
            // detailMediaFocusIndex behind the overlay, invisible but still there for when it
            // closes). appState.detailTrailerActive is set by DetailView, which is the only
            // place that actually knows each media item's type.
            if appState.detailMediaOverlayIndex != nil, appState.detailTrailerActive {
                switch kc {
                case 53:
                    appState.detailMediaOverlayIndex = nil
                    appState.detailTrailerActive = false
                    trailerScrubDirection = 0
                case 123: scrubTrailer(direction: -1)
                case 124: scrubTrailer(direction: 1)
                case 36, 49: appState.trailerCommand = .togglePlayPause
                default: break
                }
                return true
            }
            switch kc {
            case 53:
                if appState.detailMediaOverlayIndex != nil {
                    appState.detailMediaOverlayIndex = nil
                } else if appState.detailMediaFocusIndex != nil {
                    appState.detailMediaFocusIndex = nil
                } else {
                    closeDetail()
                }
            case 123:
                if appState.detailMediaOverlayIndex != nil {
                    // Screenshot overlay — Left/Right has nothing to do (no scrub target).
                } else if let idx = appState.detailMediaFocusIndex {
                    appState.detailMediaFocusIndex = max(0, idx - 1)
                } else {
                    detailFocusIdx = max(0, detailFocusIdx - 1)
                }
            case 124:
                if appState.detailMediaOverlayIndex != nil {
                    // Screenshot overlay — same as above.
                } else if let idx = appState.detailMediaFocusIndex {
                    appState.detailMediaFocusIndex = min(appState.detailMediaItemCount - 1, idx + 1)
                } else {
                    detailFocusIdx = min(3, detailFocusIdx + 1)
                }
            case 126:
                if appState.detailMediaFocusIndex == nil, appState.detailMediaItemCount > 0 {
                    appState.detailMediaFocusIndex = 0
                }
            case 125:
                if appState.detailMediaFocusIndex != nil { appState.detailMediaFocusIndex = nil }
            case 36, 49:
                if let idx = appState.detailMediaFocusIndex, appState.detailMediaOverlayIndex == nil {
                    appState.detailMediaOverlayIndex = idx
                } else if appState.detailMediaOverlayIndex == nil {
                    executeDetailAction(detailFocusIdx, game: game)
                }
            default: break
            }
            return true
        }
        guard appState.fixCoverTarget == nil, appState.fixBannerTarget == nil,
              appState.artSourcePreference != .notConfigured else { return false }
        let count = appState.filteredGames.count
        // Empty library/filter: game navigation has nothing to do, but the pause menu (and
        // through it Refresh/Settings/Quit) must stay reachable — a couch setup with zero
        // games would otherwise be a keyboard/controller dead end.
        guard count > 0 else {
            if kc == 53 { openPauseMenu(); return true }
            return false
        }

        // Music widget zone — same in every view mode.
        if uiFocus == .musicPlayer { handleMusicKey(kc); return true }

        if appState.viewMode == .carousel {
            switch uiFocus {
            case .carousel:
                switch kc {
                case 123: navigateDelta(-1)
                case 124: navigateDelta(+1)
                case 126:
                    uiFocus = .searchSort
                    searchSortFocusIdx = 0
                case 125: uiFocus = .bottomControls
                case 36, 49: openDetail()
                case 53: openPauseMenu()   // Esc/B at the top level = the pause menu
                default: return false
                }
                return true
            case .topBar:         return handleTopBarKey(kc)
            case .searchSort:     return handleSearchSortKey(kc)
            case .bottomControls: return handleBottomControlsKey(kc)
            case .musicPlayer:    return true
            case .listActions:    return true   // carousel mode never enters this zone
            }
        }

        // Rainbow Slide reuses the exact same zone (.carousel) as the flat carousel — Up/Down/
        // Enter/Esc all mean the same thing — but Left/Right go through navigateRainbowSlide's
        // pinned-edge-then-spin model instead of a plain ±1 navigateDelta step (see ui-views.md).
        if appState.viewMode == .rainbowSlide {
            switch uiFocus {
            case .carousel:
                switch kc {
                case 123: navigateRainbowSlide(-1)
                case 124: navigateRainbowSlide(+1)
                case 126:
                    uiFocus = .searchSort
                    searchSortFocusIdx = 0
                case 125: uiFocus = .bottomControls
                case 36, 49: openDetail()
                case 53: openPauseMenu()
                default: return false
                }
                return true
            case .topBar:         return handleTopBarKey(kc)
            case .searchSort:     return handleSearchSortKey(kc)
            case .bottomControls: return handleBottomControlsKey(kc)
            case .musicPlayer:    return true
            case .listActions:    return true
            }
        }

        // Grid / Big / Wall / List / Compact List — colCount drives up/down row jumps (the two
        // master/detail modes are a single column).
        let winWidth = NSApp.keyWindow?.contentView?.frame.width ?? 1200
        let colCount: Int
        switch appState.viewMode {
        case .big:  colCount = max(1, Int((winWidth - 48) / 342))
        case .grid: colCount = max(1, Int((winWidth - 40) / 176))
        case .wall: colCount = max(1, Int((winWidth - 28) / 130))
        default:    colCount = 1
        }
        // Both master/detail view modes (List's banner rows, Compact List's flat table rows)
        // share the same row-browsing/action-row split — see the Right-arrow and Enter cases.
        let isMasterDetail = appState.viewMode == .list || appState.viewMode == .compactList

        switch uiFocus {
        case .carousel:
            switch kc {
            case 123: navigateDelta(-1)
            case 124:
                // Master/detail split: Right hands off from row-browsing into the inline
                // Play/Favorite/Hide row on the right, instead of nudging the row selection
                // (which Left/Right otherwise mirror Up/Down for) — grid/wall/big have no such
                // panel, so they keep the plain selection-nudge behavior.
                if isMasterDetail {
                    uiFocus = .listActions
                    listActionFocusIdx = 0
                } else {
                    navigateDelta(+1)
                }
            case 125:
                if appState.selectedIndex + colCount >= count {
                    uiFocus = .bottomControls; bottomFocusIdx = 0
                } else {
                    navigateDelta(colCount)
                }
            case 126:
                if appState.selectedIndex < colCount {
                    uiFocus = .searchSort
                    searchSortFocusIdx = 0
                } else {
                    navigateDelta(-colCount)
                }
            // Master/detail modes have no modal Detail page — Enter launches directly.
            case 36, 49: isMasterDetail ? launchSelected() : openDetail()
            case 53: openPauseMenu()   // Esc/B at the top level = the pause menu
            default: return false
            }
            return true
        case .topBar:         return handleTopBarKey(kc)
        case .searchSort:     return handleSearchSortKey(kc)
        case .bottomControls: return handleBottomControlsKey(kc)
        case .musicPlayer:    return true
        case .listActions:    return handleListActionsKey(kc)
        }
    }

    // Trailing slots after the view-mode buttons — full-screen toggle, then the pause-menu gear.
    // Neither had a keyboard/controller focus stop before v0.25.0 (mouse-only), so a couch
    // controller session with no keyboard/mouse in hand had no way to reach them at all.
    // Not `private` — ContentView+Chrome.swift's topBar view reads these too, and `private` on an
    // extension member only reaches same-FILE extensions of ContentView, not other +Chrome/+Input
    // files (see architecture.md's file-layout note on why these extensions stay non-private).
    var topBarFullScreenIdx: Int { visibleFilters.count + AppState.ViewMode.allCases.count }
    var topBarGearIdx: Int { topBarFullScreenIdx + 1 }

    private func handleTopBarKey(_ kc: UInt16) -> Bool {
        let lastIdx = topBarGearIdx
        switch kc {
        case 123: topBarFocusIdx = max(0, topBarFocusIdx - 1)
        case 124: topBarFocusIdx = min(lastIdx, topBarFocusIdx + 1)
        case 125: uiFocus = .searchSort; searchSortFocusIdx = 0
        case 53:  uiFocus = .carousel
        case 36, 49:
            if topBarFocusIdx < visibleFilters.count {
                if let filter = visibleFilters[safe: topBarFocusIdx] {
                    appState.sourceFilter = filter
                    appState.selectedIndex = 0
                    if appState.viewMode == .carousel {
                        carousel.loadGames(appState.filteredGames, animated: false)
                        applyArtToCarousel()
                    }
                    if appState.viewMode == .rainbowSlide {
                        rainbowSlide.loadGames(appState.filteredGames)
                        applyArtToRainbowSlide()
                    }
                }
                uiFocus = .carousel
            } else if topBarFocusIdx == topBarFullScreenIdx {
                session.appDelegate?.toggleFullScreen()
            } else if topBarFocusIdx == topBarGearIdx {
                togglePauseMenu()
            } else {
                let modeIdx = topBarFocusIdx - visibleFilters.count
                let modes = AppState.ViewMode.allCases
                if modeIdx < modes.count {
                    withAnimation(.easeInOut(duration: 0.15)) { appState.viewMode = modes[modeIdx] }
                    if modes[modeIdx] == .carousel {
                        carousel.loadGames(appState.filteredGames, animated: false,
                                           selectedIndex: appState.selectedIndex)
                        applyArtToCarousel()
                    }
                    if modes[modeIdx] == .rainbowSlide {
                        rainbowSlide.loadGames(appState.filteredGames, selectedIndex: appState.selectedIndex)
                        applyArtToRainbowSlide()
                    }
                }
                uiFocus = .carousel
            }
        default: break
        }
        return true
    }

    // The search + sort pill row. 0=search pill, 1=sort pill.
    // Enter/Space on the search pill requests real text-edit focus (SearchSortBar's own
    // @FocusState picks up appState.searchEditing and focuses the field); on the sort pill it
    // cycles to the next SortOption — mouse users get the full native dropdown by clicking
    // (SwiftUI has no public API to pop a Menu programmatically, so keyboard/controller cycle
    // instead; every option is still reachable either way).
    private func handleSearchSortKey(_ kc: UInt16) -> Bool {
        switch kc {
        case 123: searchSortFocusIdx = max(0, searchSortFocusIdx - 1)
        case 124: searchSortFocusIdx = min(1, searchSortFocusIdx + 1)
        case 126:
            uiFocus = .topBar
            topBarFocusIdx = visibleFilters.firstIndex(of: appState.sourceFilter) ?? 0
        case 125, 53: uiFocus = .carousel
        case 36, 49:
            if searchSortFocusIdx == 0 { appState.searchEditing = true }
            else { appState.cycleSortOption() }
        default: break
        }
        return true
    }

    // Indices: 0=motion toggle, 1=hero backdrop toggle, 2-4=theme swatches, 5=Buy Me A Coffee.
    private func handleBottomControlsKey(_ kc: UInt16) -> Bool {
        switch kc {
        case 123:
            if bottomFocusIdx == 0 {
                // With the widget switched off there's nothing to the left — stay put rather
                // than focusing a zone that isn't on screen.
                guard musicPlayer.isEnabled else { break }
                uiFocus = .musicPlayer; musicPlayerFocusIdx = 1
            } else {
                bottomFocusIdx -= 1
            }
        case 124: bottomFocusIdx = min(Self.coffeeFocusIdx, bottomFocusIdx + 1)
        case 126, 53: uiFocus = .carousel
        case 36, 49:
            switch bottomFocusIdx {
            case 0: appState.setMotion(!appState.motionEnabled)
            case 1: appState.setHeroBackground(!appState.heroBackgroundEnabled)
            case Self.coffeeFocusIdx:
                NSWorkspace.shared.open(URL(string: "https://www.buymeacoffee.com/jackharvest")!)
            default:
                let themes = AppState.AppTheme.allCases
                let themeIdx = bottomFocusIdx - 2
                if themeIdx < themes.count {
                    appState.setTheme(themes[themeIdx])
                }
            }
        default: break
        }
        return true
    }

    // List view's inline Play/Favorite/Hide row (right-hand detail panel). Entered from the
    // row list via Right; Left off idx=0 (or Esc/Up/Down) returns to row browsing — same
    // "focus ring can't be in two places" rule as the Detail page's action bar/media rail.
    private func handleListActionsKey(_ kc: UInt16) -> Bool {
        switch kc {
        case 123:
            if listActionFocusIdx == 0 { uiFocus = .carousel } else { listActionFocusIdx -= 1 }
        case 124: listActionFocusIdx = min(2, listActionFocusIdx + 1)
        case 125, 126, 53: uiFocus = .carousel
        case 36, 49:
            guard let game = appState.filteredGames[safe: appState.selectedIndex] else { break }
            switch listActionFocusIdx {
            // Gated behind PLAY hold-to-confirm (decisions.md #96).
            case 0: appState.beginPlayHold(game) { [session] in session.launch(game) }
            case 1:
                withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) {
                    appState.toggleFavorite(game)
                }
            case 2: appState.hideGame(game)
            default: break
            }
        default: break
        }
        return true
    }

    // MARK: - Music widget navigation

    // Music widget nav. Layout (focus indices):
    //   header row: repeat(4) settings(5) minimize(6)
    //   bottom row: volume(3) prev(0) play(1) next(2)
    // ←/→ move within a row; ↑/↓ move between rows; on volume(3) ↑/↓ change the volume.
    // → past the row's last control (or Esc) exits to bottom controls; ←/↑/↓ never kick you out.
    private func handleMusicKey(_ kc: UInt16) {
        guard musicPlayer.isExpanded else {
            switch kc {   // collapsed pill: 0=play, 1=expand
            case 123: musicPlayerFocusIdx = 0
            case 124:
                if musicPlayerFocusIdx >= 1 { uiFocus = .bottomControls; bottomFocusIdx = 0 }
                else { musicPlayerFocusIdx = 1 }
            case 53: uiFocus = .bottomControls
            case 36, 49: fireMusicPlayerControl(musicPlayerFocusIdx)
            default: break
            }
            return
        }
        switch kc {
        case 123: musicPlayerFocusIdx = musicLeft(musicPlayerFocusIdx)
        case 124:
            if let next = musicRight(musicPlayerFocusIdx) { musicPlayerFocusIdx = next }
            else { uiFocus = .bottomControls; bottomFocusIdx = 0 }
        case 126:
            if musicPlayerFocusIdx == 3 { musicPlayer.setVolume(min(Float(1), musicPlayer.volume + 0.05)) }
            else { musicPlayerFocusIdx = musicVertical(musicPlayerFocusIdx, up: true) }
        case 125:
            if musicPlayerFocusIdx == 3 { musicPlayer.setVolume(max(Float(0), musicPlayer.volume - 0.05)) }
            else { musicPlayerFocusIdx = musicVertical(musicPlayerFocusIdx, up: false) }
        case 53: uiFocus = .bottomControls
        case 36, 49: fireMusicPlayerControl(musicPlayerFocusIdx)
        default: break
        }
    }

    // Fires the focused control inside the music player zone.
    // Expanded: 0=prev 1=play 2=next 3=volume(no-op) 4=pin 5=settings 6=minimize
    // Collapsed: 0=play 1=expand
    private func fireMusicPlayerControl(_ idx: Int) {
        if !musicPlayer.isExpanded {
            switch idx {
            case 0: musicPlayer.toggle()
            case 1: withAnimation(.spring(response: 0.28, dampingFraction: 0.80)) { musicPlayer.isExpanded = true }
            default: break
            }
            return
        }
        switch idx {
        case 0: musicPlayer.previousTrack()
        case 1: musicPlayer.toggle()
        case 2: musicPlayer.nextTrack()
        case 3: break  // volume — navigate through but no enter action
        case 4: withAnimation(.spring(response: 0.20, dampingFraction: 0.75)) { musicPlayer.toggleSticky() }
        case 5: musicSettingsPanel.open(player: musicPlayer)
        case 6: withAnimation(.spring(response: 0.28, dampingFraction: 0.80)) { musicPlayer.isExpanded = false }
        default: break
        }
    }

    private static let musicRows: [[Int]] = [[4, 5, 6], [3, 0, 1, 2]]
    private func musicPos(_ idx: Int) -> (row: Int, col: Int) {
        for (r, row) in Self.musicRows.enumerated() {
            if let c = row.firstIndex(of: idx) { return (r, c) }
        }
        return (1, 0)
    }
    private func musicLeft(_ idx: Int) -> Int {
        let p = musicPos(idx)
        return Self.musicRows[p.row][max(0, p.col - 1)]
    }
    private func musicRight(_ idx: Int) -> Int? {   // nil = exit the zone
        let p = musicPos(idx)
        let row = Self.musicRows[p.row]
        return p.col + 1 < row.count ? row[p.col + 1] : nil
    }
    private func musicVertical(_ idx: Int, up: Bool) -> Int {
        let p = musicPos(idx)
        let target = up ? p.row - 1 : p.row + 1
        guard target >= 0, target < Self.musicRows.count else { return idx }
        let row = Self.musicRows[target]
        return row[min(p.col, row.count - 1)]
    }

    // MARK: - Trailer scrubbing

    // eShop-style trailer scrub: base 10s step, doubling every 20s the user keeps skipping in
    // the same direction (a held key auto-repeats far faster than that — the 0.12s throttle
    // below keeps the actual seek rate sane while still letting the streak clock run on the
    // real elapsed time, not the repeat count). A pause over 0.6s or a direction change starts
    // a fresh streak, same as picking the skip back up from a stop.
    private func scrubTrailer(direction: Int) {
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastTrailerScrub > 0.12 else { return }
        if direction != trailerScrubDirection || now - lastTrailerScrub > 0.6 {
            trailerScrubStreakStart = now
            trailerScrubDirection = direction
        }
        lastTrailerScrub = now
        let elapsed = now - trailerScrubStreakStart
        let multiplier = 1 + Int(elapsed / 20.0)
        appState.trailerCommand = .scrub(seconds: 10.0 * Double(multiplier) * Double(direction))
    }

    // MARK: - Carousel focus ring

    // Show the selection ring when the carousel zone is focused. With the mouse it also
    // requires the cursor to be over the carousel (hover-in shows it, hover-out hides it);
    // for keyboard/controller it always shows while the carousel zone is active.
    func updateCarouselRing() {
        if appState.viewMode == .carousel {
            let show = uiFocus == .carousel && (appState.lastInputMethod != .mouse || carouselHovered)
            carousel.setCarouselFocused(show)
        }
        if appState.viewMode == .rainbowSlide {
            // Rainbow Slide's own hover ring (setHovered) is a separate, always-live signal from
            // the mouse — this only governs the KEYBOARD/CONTROLLER ring, hidden the same way
            // the carousel's is whenever focus leaves the zone or the mouse takes over.
            let show = uiFocus == .carousel && (appState.lastInputMethod != .mouse || carouselHovered)
            rainbowSlide.setFocused(show)
        }
    }
}
