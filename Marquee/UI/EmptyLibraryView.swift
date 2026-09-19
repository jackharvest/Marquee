import SwiftUI

// Shown in place of a blank carousel when there's nothing to display. Two situations, one view:
//  - The whole library is empty (fresh install, nothing scanned) → explain where Marquee looks
//    for games and offer a re-scan.
//  - Only the CURRENT FILTER is empty (e.g. the Epic chip with no Epic games installed) → a
//    lighter "nothing from this source" note, since the library itself is fine.
struct EmptyLibraryView: View {
    @Environment(AppState.self) private var appState

    let onRefresh: () -> Void

    private var wholeLibraryEmpty: Bool { appState.games.isEmpty }

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: wholeLibraryEmpty ? "square.stack.3d.up.slash" : "line.3.horizontal.decrease.circle")
                .font(.system(size: 42, weight: .light))
                .foregroundStyle(.white.opacity(0.35))

            Text(wholeLibraryEmpty ? "No games found yet" : "No \(appState.sourceFilter.label) games")
                .font(.system(size: 22, weight: .bold, design: .rounded))
                .foregroundStyle(.white)

            if wholeLibraryEmpty {
                Text("""
                Marquee scans these places automatically:

                •  CrossOver bottles (Windows games, incl. a bottled Steam library)
                •  Steam for Mac  •  Epic Games Launcher  •  GOG
                •  Mac App Store games in /Applications
                •  Any external drive that's plugged in

                Games somewhere else? Point Marquee at the folder that holds
                them — the one your .app game files actually sit in.
                """)
                .font(.system(size: 12.5))
                .foregroundStyle(.white.opacity(0.6))
                .multilineTextAlignment(.center)
                .lineSpacing(3)
            } else {
                Text("Nothing from this source is installed. Pick another filter above, or refresh if you just installed something.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(.white.opacity(0.6))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 380)
            }

            // "Where do I even point it?" is the first-run question an empty library raises,
            // so the answer is a button right here rather than a trip to Preferences ▸ Custom
            // Library — that's where the picker lives, but nothing on this
            // screen used to say so.
            HStack(spacing: 10) {
                if wholeLibraryEmpty {
                    Button { appState.promptAddScanFolder() } label: {
                        pillLabel("folder.badge.plus", "Add Games Folder…")
                    }
                    .buttonStyle(.plain)
                    .hoverHighlight(scale: 1.05, brighten: 0.1)
                }

                Button(action: onRefresh) {
                    pillLabel("arrow.clockwise", "Refresh Library")
                }
                .buttonStyle(.plain)
                .hoverHighlight(scale: 1.05, brighten: 0.1)
            }

            Text(wholeLibraryEmpty
                 ? "⌘R any time — or drop a folder straight onto this window"
                 : "⌘R any time — or the pause menu (Esc)")
                .font(.system(size: 10.5))
                .foregroundStyle(.white.opacity(0.3))
        }
        .padding(.horizontal, 40)
        .padding(.vertical, 34)
        .frame(maxWidth: 560)
        .background(
            RoundedRectangle(cornerRadius: 18)
                .fill(Color(red: 0.07, green: 0.04, blue: 0.14).opacity(0.88))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18)
                .strokeBorder(Color.white.opacity(0.1), lineWidth: 1)
        )
        .allowsHitTesting(true)
    }

    private func pillLabel(_ icon: String, _ title: String) -> some View {
        HStack(spacing: 7) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
            Text(title)
                .font(.system(size: 13, weight: .semibold))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .background(Capsule().fill(Color(red: 0.76, green: 0.46, blue: 1.0).opacity(0.35)))
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.25), lineWidth: 1))
        .contentShape(Capsule())
    }
}
