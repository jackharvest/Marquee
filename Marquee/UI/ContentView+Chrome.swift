import SwiftUI
import AppKit

// The window "chrome" around the main content: top nav bar, bottom-right control cluster,
// the loading-logo overlay, the carousel's game info bar, and the small input-method badge.

extension ContentView {

    // MARK: - Top Bar

    var topBar: some View {
        HStack(spacing: 0) {
            // Logo + title — left anchor, fixed min-width so filter chips stay centered.
            // 72px logo used as-is (no resize) for max crispness on Retina.
            HStack(spacing: 8) {
                if let img = loadSmallLogoFromBundle() {
                    Image(nsImage: img)
                        .offset(y: 18)   // push the icon down so it isn't flush to the window top
                        .shadow(color: .black.opacity(0.55), radius: 10, x: 0, y: 4)
                        .allowsHitTesting(false)
                }
                if let titleImg = loadTitleFromBundle() {
                    Image(nsImage: titleImg)
                        .resizable()
                        .scaledToFit()
                        .frame(height: 20)
                        .opacity(0.95)
                        .offset(y: 5)
                } else {
                    Text("Marquee")
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                }
            }
            .frame(minWidth: 170, alignment: .leading)

            Spacer()

            // Source filter chips — centered; highlighted when keyboard-navigating to topBar zone
            HStack(spacing: 6) {
                ForEach(Array(visibleFilters.enumerated()), id: \.element) { idx, filter in
                    Button(filter.label) {
                        appState.sourceFilter = filter
                        appState.selectedIndex = 0
                        uiFocus = .carousel
                        if appState.viewMode == .carousel {
                            carousel.loadGames(appState.filteredGames, animated: false)
                            applyArtToCarousel()
                        }
                        if appState.viewMode == .rainbowSlide {
                            rainbowSlide.loadGames(appState.filteredGames)
                            applyArtToRainbowSlide()
                        }
                    }
                    .buttonStyle(FilterChipStyle(
                        isActive: appState.sourceFilter == filter,
                        isDim: filter == .hidden,
                        isFocused: uiFocus == .topBar && topBarFocusIdx == idx
                    ))
                    .hoverHighlight(scale: 1.08, brighten: 0.12)
                }
            }

            Spacer()

            // View mode buttons — right anchor, same min-width as logo group
            HStack(spacing: 4) {
                ForEach(Array(AppState.ViewMode.allCases.enumerated()), id: \.element) { idx, mode in
                    Button {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            appState.viewMode = mode
                        }
                        if mode == .carousel {
                            carousel.loadGames(appState.filteredGames, animated: false,
                                               selectedIndex: appState.selectedIndex)
                            applyArtToCarousel()
                        }
                        if mode == .rainbowSlide {
                            rainbowSlide.loadGames(appState.filteredGames, selectedIndex: appState.selectedIndex)
                            applyArtToRainbowSlide()
                        }
                    } label: {
                        modeIcon(mode)
                            .frame(width: 34, height: 28)
                            .foregroundStyle(appState.viewMode == mode ? .white : .white.opacity(0.38))
                            .background(appState.viewMode == mode ? Color.white.opacity(0.18) : .clear)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .strokeBorder(
                                        uiFocus == .topBar && topBarFocusIdx == visibleFilters.count + idx
                                            ? Color.white.opacity(0.9) : Color.clear,
                                        lineWidth: 2
                                    )
                            )
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .hoverHighlight(scale: 1.1, brighten: 0.12)
                    .help(mode.label)
                }

                Rectangle()
                    .fill(.white.opacity(0.18))
                    .frame(width: 1, height: 16)
                    .padding(.horizontal, 2)

                // Full-screen toggle — mouse affordance (also ⌥⏎ / ⌃⌘F).
                // NSApp.delegate is SwiftUI's own wrapper around AppDelegate, not the instance
                // itself, so casting it (the old code) silently failed and this button did
                // nothing — session.appDelegate is the same weak reference GameSessionManager
                // already uses to reach the real AppDelegate.
                Button { session.appDelegate?.toggleFullScreen() } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(width: 30, height: 28)
                        .foregroundStyle(.white.opacity(0.55))
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .strokeBorder(
                                    uiFocus == .topBar && topBarFocusIdx == topBarFullScreenIdx
                                        ? Color.white.opacity(0.9) : Color.clear,
                                    lineWidth: 2
                                )
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .hoverHighlight(scale: 1.1, brighten: 0.12)
                .help("Toggle Full Screen (⌥⏎ / ⌃⌘F)")

                // Pause menu — the mouse affordance for the same overlay Esc / a controller's
                // Menu button raises. Crucial in full screen, where the menu bar is hidden.
                Button { togglePauseMenu() } label: {
                    Image(systemName: "gearshape.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(width: 30, height: 28)
                        .foregroundStyle(.white.opacity(0.55))
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .strokeBorder(
                                    uiFocus == .topBar && topBarFocusIdx == topBarGearIdx
                                        ? Color.white.opacity(0.9) : Color.clear,
                                    lineWidth: 2
                                )
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .hoverHighlight(scale: 1.1, brighten: 0.12)
                .help("Pause Menu (Esc / controller Menu button)")
            }
            .frame(minWidth: 170, alignment: .trailing)
        }
        .padding(.leading, 10)
        .padding(.trailing, 18)
        .padding(.vertical, 10)
        .frame(height: 52)
        .background(Color(red: 0.18, green: 0.04, blue: 0.44).opacity(0.82))
    }

    // View-mode nav icon — a plain SF Symbol for every mode except Carousel, which gets a
    // small hand-drawn glyph instead (decisions.md #102): the generic "stack of squares" symbol
    // read as just another grid variant, nothing like the carousel's actual arc-with-a-raised-
    // center layout. Three bars, short-tall-short, reads as that layout at a glance instead.
    @ViewBuilder
    private func modeIcon(_ mode: AppState.ViewMode) -> some View {
        if mode == .carousel {
            CarouselModeIcon()
        } else {
            Image(systemName: mode.sfSymbol)
                .font(.system(size: 13, weight: .semibold))
        }
    }

    // MARK: - Buy Me A Coffee badge

    // Reachable as the last stop in the bottomControls zone (past the theme swatches) —
    // decisions.md #91 deliberately left it out of the focus chain since it lived in its own
    // VStack above bottomControls, not inside it; that's still true visually, but there's no
    // reason it can't be one more stop in the same zone (see Self.coffeeFocusIdx).
    static let coffeeFocusIdx = 5

    var coffeeButton: some View {
        let isFocused = uiFocus == .bottomControls && bottomFocusIdx == Self.coffeeFocusIdx
        let tooltipText = "Support Marquee's development — opens buymeacoffee.com in your browser"
        return Button {
            NSWorkspace.shared.open(URL(string: "https://www.buymeacoffee.com/jackharvest")!)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "cup.and.saucer.fill")
                    .font(.system(size: 11, weight: .bold))
                Text("Prove my wife wrong.")
                    .font(.system(size: 11, weight: .bold))
            }
            .foregroundStyle(.black)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color(red: 1.0, green: 0.867, blue: 0.0))
            .clipShape(RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color.black, lineWidth: 1.3))
            .overlay(
                RoundedRectangle(cornerRadius: 7)
                    .strokeBorder(isFocused ? Color.white.opacity(0.9) : .clear, lineWidth: 2.5)
                    .padding(-3)
            )
        }
        .buttonStyle(.plain)
        .shadow(color: .black.opacity(0.35), radius: 3, x: 0, y: 1)
        .opacity(coffeeButtonHovered || isFocused || !coffeeButtonDimmed ? 1.0 : 0.3)
        .animation(.easeInOut(duration: 0.2), value: coffeeButtonHovered)
        .onHover { coffeeButtonHovered = $0 }
        // .help(...) still carries the explanation for VoiceOver/accessibility, but its visible
        // bubble is macOS's own system tooltip, which only appears after ~1.5s of hover — too
        // slow for a button whose click jumps straight to a browser and silently drops the app's
        // controller-navigation context to keyboard/mouse (Jack's ask: show it instantly instead).
        // The overlay below is a second, custom tooltip that fades in immediately on hover OR
        // keyboard/controller focus, with no system delay.
        .help(tooltipText)
        .overlay(alignment: .top) {
            if coffeeButtonHovered || isFocused {
                Text(tooltipText)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(width: 200)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(RoundedRectangle(cornerRadius: 7).fill(Color.black.opacity(0.92)))
                    .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color.white.opacity(0.15), lineWidth: 1))
                    .offset(y: -52)
                    .transition(.opacity)
                    .allowsHitTesting(false)
            }
        }
        .inputHint(isFocused ? .confirm : nil, method: appState.lastInputMethod)
    }

    // MARK: - Bottom Controls (motion toggle + theme swatches + version badge)
    // White ring appears on the focused item when the bottomControls zone is active.

    var bottomControls: some View {
        HStack(spacing: 7) {
            Button { appState.setMotion(!appState.motionEnabled) } label: {
                Image(systemName: "waveform")
                    .font(.system(size: 11, weight: appState.motionEnabled ? .bold : .regular))
                    .foregroundStyle(appState.motionEnabled ? .white.opacity(0.85) : .white.opacity(0.22))
                    .frame(width: 18, height: 18)
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .strokeBorder(
                                uiFocus == .bottomControls && bottomFocusIdx == 0
                                    ? Color.white.opacity(0.9) : .clear,
                                lineWidth: 2
                            )
                            .padding(-4)
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .hoverHighlight()
            .help("Toggle motion animation (Down arrow from carousel)")
            .animation(.easeInOut(duration: 0.15), value: appState.motionEnabled)

            Button { appState.setHeroBackground(!appState.heroBackgroundEnabled) } label: {
                Image(systemName: "photo.fill")
                    .font(.system(size: 11, weight: appState.heroBackgroundEnabled ? .bold : .regular))
                    .foregroundStyle(appState.heroBackgroundEnabled ? .white.opacity(0.85) : .white.opacity(0.22))
                    .frame(width: 18, height: 18)
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .strokeBorder(
                                uiFocus == .bottomControls && bottomFocusIdx == 1
                                    ? Color.white.opacity(0.9) : .clear,
                                lineWidth: 2
                            )
                            .padding(-4)
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .hoverHighlight()
            .help("Toggle game backdrop art")
            .animation(.easeInOut(duration: 0.15), value: appState.heroBackgroundEnabled)

            Rectangle()
                .fill(.white.opacity(0.18))
                .frame(width: 1, height: 10)

            ForEach(Array(AppState.AppTheme.allCases.enumerated()), id: \.element) { idx, theme in
                themeSwatch(idx: idx, theme: theme)
            }

            Text("v0.37.0")
                .font(.system(size: 11, weight: .regular, design: .monospaced))
                .foregroundStyle(.white.opacity(0.18))
        }
    }

    private func themeSwatch(idx: Int, theme: AppState.AppTheme) -> some View {
        Button { appState.setTheme(theme) } label: {
            Circle()
                .fill(theme.swatch)
                .frame(width: 12, height: 12)
                // Always-on rim so the near-black "Black" swatch stays visible.
                .overlay(Circle().strokeBorder(Color.white.opacity(0.38), lineWidth: 1))
                .overlay(
                    Circle().strokeBorder(
                        appState.currentTheme == theme ? Color.white : Color.clear,
                        lineWidth: 2
                    )
                )
                .overlay(
                    Circle().strokeBorder(
                        uiFocus == .bottomControls && bottomFocusIdx == idx + 2
                            ? Color.white.opacity(0.9) : .clear,
                        lineWidth: 2
                    )
                    .padding(-4)
                )
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .hoverHighlight()
        .help(theme.label)
    }

    // MARK: - Loading overlay + info bar + input badge

    var logoOverlay: some View {
        ZStack {
            appState.currentTheme.backgroundColor.ignoresSafeArea()
            if let img = NSImage(named: "AppIcon") ?? loadLogoFromBundle() {
                Image(nsImage: img)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 200, height: 200)
                    .opacity(logoOpacity)
                    .scaleEffect(logoScale)
                    .blur(radius: logoBlur)
            }
        }
        .allowsHitTesting(false)
    }

    var gameInfoBar: some View {
        let game = appState.filteredGames[safe: appState.selectedIndex]
        return VStack(spacing: 6) {
            if let game {
                HStack(spacing: 8) {
                    SourceBadge(game: game)
                    if !game.isInstalled {
                        Text("NOT INSTALLED")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.7))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(Color.white.opacity(0.15)))
                    }
                }
                Text(game.title)
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.9), radius: 6, x: 0, y: 2)
                Text("Press Return to launch")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.4))
            }
        }
        .padding(.bottom, 36)
        .animation(.easeInOut(duration: 0.2), value: game?.id)
    }

    // Amber "offline" pill shown next to the input badge while disconnected. Cached art, the
    // library itself, and launching installed games all keep working — this exists so missing
    // covers/details read as "no internet right now," not "Marquee is broken."
    var offlineBadge: some View {
        HStack(spacing: 5) {
            Image(systemName: "wifi.slash")
                .font(.system(size: 10, weight: .semibold))
            Text("OFFLINE")
                .font(.system(size: 9, weight: .bold))
        }
        .foregroundStyle(Color(red: 1.0, green: 0.75, blue: 0.35))
        .padding(.horizontal, 8)
        .frame(height: 24)
        .background(RoundedRectangle(cornerRadius: 5).fill(Color(red: 0.4, green: 0.25, blue: 0.05).opacity(0.55)))
        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color(red: 1.0, green: 0.75, blue: 0.35).opacity(0.35), lineWidth: 0.5))
        .help("No internet connection — cached art and installed games still work; new art and game details resume when you're back online")
        .transition(.opacity)
    }

    // Subtle input-method badge positioned just below the top bar on the right.
    var inputMethodBadge: some View {
        let (icon, hint): (String, String) = {
            switch appState.lastInputMethod {
            case .keyboard:   return ("keyboard", "Keyboard / WASD")
            case .mouse:      return ("cursorarrow", "Mouse")
            case .controller: return ("gamecontroller", "Controller")
            }
        }()
        return Image(systemName: icon)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.white.opacity(0.42))
            .frame(width: 24, height: 24)
            .background(RoundedRectangle(cornerRadius: 5).fill(Color.white.opacity(0.09)))
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5))
            .help(hint)
            .animation(.easeInOut(duration: 0.25), value: appState.lastInputMethod)
    }

    // MARK: - Bundled logo assets

    // 128px logo for the loading overlay (large splash)
    private func loadLogoFromBundle() -> NSImage? {
        guard let url = Bundle.main.url(forResource: "Marquee-logo-icon_128", withExtension: "png") else { return nil }
        return NSImage(contentsOf: url)
    }

    // 72px logo for the nav bar — used as-is (no SwiftUI resize) for crispness on Retina
    private func loadSmallLogoFromBundle() -> NSImage? {
        guard let url = Bundle.main.url(forResource: "Marquee-logo-icon_72", withExtension: "png") else { return nil }
        return NSImage(contentsOf: url)
    }

    // Title wordmark image ("Marquee") to replace the plain-text title in the nav bar
    private func loadTitleFromBundle() -> NSImage? {
        guard let url = Bundle.main.url(forResource: "Marqee-Title", withExtension: "png") else { return nil }
        return NSImage(contentsOf: url)
    }
}

// Three bars, short-tall-short — the carousel's own silhouette (side boxes scaled down, the
// centered one scaled up) in miniature. `.foregroundStyle` from the call site colors it exactly
// like an SF Symbol would (RoundedRectangle picks up the ambient foreground style same as Image).
private struct CarouselModeIcon: View {
    var body: some View {
        HStack(alignment: .center, spacing: 2) {
            RoundedRectangle(cornerRadius: 1.3).frame(width: 4, height: 10)
            RoundedRectangle(cornerRadius: 1.6).frame(width: 5, height: 15)
            RoundedRectangle(cornerRadius: 1.3).frame(width: 4, height: 10)
        }
    }
}
