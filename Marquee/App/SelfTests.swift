import AppKit

// Debug-only self-test harnesses, gated behind environment variables so they never run for
// normal users:
//
//   MARQUEE_SELFTEST=1  — audits Game.id stability/uniqueness and Fix Cover targeting,
//                         prints PASS/FAIL lines, then exits 0 (all good) or 1 (broken).
//   MARQUEE_SIZECHECK=1 — prints each game's resolved install folder, measured size, and
//                         what PLAY would launch, then exits.
//   MARQUEE_SCANTEST=1  — builds a throwaway folder tree shaped like the real drive layouts
//                         people keep games in, runs the custom-folder scanner over it, and
//                         checks what it found against what it should have found.
//
// Both are invoked from ContentView.revealApp() once the library is loaded, so they audit
// the exact game list a real session would show.
@MainActor
enum SelfTests {

    // MARK: - Game.id uniqueness + Fix Cover targeting audit (MARQUEE_SELFTEST)
    // Every game's stable UUID must resolve back to itself — a collision means Fix Cover
    // overrides and cached art would bleed between games.

    static func runUUIDAudit(appState: AppState) {
        let games = appState.filteredGames
        guard !games.isEmpty else { print("[SELFTEST] no games"); return }

        func log(_ s: String) { print(s); fflush(stdout) }

        Task { @MainActor in
            log("[SELFTEST] ===== Game.id uniqueness audit (\(games.count) games) =====")

            // 1) Dump every game's id + source key; detect collisions.
            var idToTitles: [String: [String]] = [:]
            for g in games {
                let key: String
                switch g.source {
                case .crossOver(let b, let p): key = "cx:\(b):\(p.isEmpty ? "<EMPTY>" : p)"
                case .steam(let a):            key = "st:\(a)"
                case .epic(let app, let c):    key = "ep:\(c):\(app)"
                case .applications(let u):     key = "app:\(u.path)"
                case .gog(let id, _):          key = "gog:\(id)"
                }
                let id8 = String(g.id.uuidString.prefix(8))
                idToTitles[g.id.uuidString, default: []].append(g.title)
                log("[SELFTEST]   '\(g.title)' id=\(id8) key=\(key)")
            }
            let collisions = idToTitles.filter { $0.value.count > 1 }
            log("[SELFTEST] collisions: \(collisions.count) UUID(s) shared by multiple games")
            for (_, titles) in collisions { log("[SELFTEST]   ⚠️ SHARED id → \(titles.joined(separator: ", "))") }

            // 2) The bug mechanism: refetchCover finds the game via firstIndex(id==).
            //    For each game, that must resolve back to ITSELF, not a collider.
            var pass = 0, total = 0
            for g in games {
                total += 1
                let resolved = games.firstIndex(where: { $0.id == g.id })
                let resolvedTitle = resolved.flatMap { games[safe: $0]?.title } ?? "nil"
                let ok = (resolvedTitle == g.title)
                if ok { pass += 1 }
                if !ok {
                    log("[SELFTEST]   FAIL: fixing '\(g.title)' would write to '\(resolvedTitle)'")
                }
            }
            log("[SELFTEST] firstIndex(id==) self-resolution: \(pass)/\(total) PASS")

            // 3) Simulate the REAL Fix Cover assignment: write each game a distinct coverSearch
            //    override (as refetchCover does), then read every one back and confirm no bleed.
            //    Only test games that actually exist — the library changes over time, so a stale
            //    hardcoded list must not fail the whole audit.
            let wantedTargets = ["Hi-Fi-RUSH", "PRAGMATA", "Rune Factory 5", "SOLARPUNK", "MOUSE"]
            let targets = wantedTargets.filter { name in games.contains { $0.title == name } }
            let ud = UserDefaults.standard
            var writtenKeys: [String] = []
            for t in targets {
                guard let g = games.first(where: { $0.title == t }) else { continue }
                let key = "coverSearch_\(g.id.uuidString)"
                ud.set("FIXED::\(t)", forKey: key)          // what FixCover writes
                writtenKeys.append(key)
            }
            var isoPass = 0
            for t in targets {
                guard let g = games.first(where: { $0.title == t }) else { continue }
                let readBack = ud.string(forKey: "coverSearch_\(g.id.uuidString)") ?? "nil"
                // The game refetchCover would update, and what its panel would autofill:
                let resolvesTo = games.first(where: { $0.id == g.id })?.title ?? "nil"
                let ok = (readBack == "FIXED::\(t)") && (resolvesTo == t)
                if ok { isoPass += 1 }
                log("[SELFTEST]   fix '\(t)' → writes/reads '\(readBack)', applies to '\(resolvesTo)' \(ok ? "PASS" : "FAIL")")
            }
            // Confirm a non-target (a game that isn't in the fix list) was untouched.
            let harv = games.first(where: { $0.title == "Harvestella" })
            let harvOverride = harv.flatMap { ud.string(forKey: "coverSearch_\($0.id.uuidString)") }
            let harvClean = (harvOverride == nil)
            log("[SELFTEST]   Harvestella override after fixing others: \(harvOverride ?? "nil") \(harvClean ? "PASS (untouched)" : "FAIL (bled!)")")
            for key in writtenKeys { ud.removeObject(forKey: key) }   // cleanup test state

            let allOK = collisions.isEmpty && pass == total && isoPass == targets.count && harvClean
            log("[SELFTEST] RESULT: \(allOK ? "ALL UNIQUE + ISOLATED — OK" : "BROKEN")")
            log("[SELFTEST] ===== done =====")
            exit(allOK ? 0 : 1)
        }
    }

    // MARK: - Custom scan-folder walk (MARQUEE_SCANTEST)
    //
    // The deep walk added for external drives can't be audited against a
    // live library the way the other two harnesses are — it depends entirely on the SHAPE of a
    // folder tree, and the interesting shapes (a drive root with games four levels down, a
    // Windows game whose only exe is in Binaries/Win64, a photo library full of bundles) aren't
    // things to go hunting for on a real disk. So the harness builds them, in a temp directory
    // it deletes afterwards, and states the expected finding for each one.
    //
    // Windows cases need at least one CrossOver bottle — without one the scanner deliberately
    // returns nothing for them, so those expectations are reported as SKIP, not FAIL.

    static func runScanCheck() {
        func log(_ s: String) { print(s); fflush(stdout) }

        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("MarqueeScanTest-\(UUID().uuidString)")

        // Nothing here needs to be a REAL app bundle or a real executable: the scanner
        // classifies by path shape (.app directory, .exe file), and titles fall back to the
        // bundle/folder name when there's no readable Info.plist — which is the same path a
        // Unity/Godot game with a minimal plist takes anyway.
        func makeApp(_ path: String) {
            try? fm.createDirectory(at: root.appendingPathComponent(path + "/Contents"),
                                    withIntermediateDirectories: true)
        }
        func makeExe(_ path: String, bytes: Int = 4096) {
            let url = root.appendingPathComponent(path)
            try? fm.createDirectory(at: url.deletingLastPathComponent(),
                                    withIntermediateDirectories: true)
            fm.createFile(atPath: url.path, contents: Data(count: bytes))
        }

        // 1. A .app right at the root of the chosen folder.
        makeApp("Thronefall.app")
        // 2. One level down — the pre-v0.37.0 scanner's limit.
        makeApp("Mac Games/Celeste.app")
        // 3. Four levels down: a drive root, the way someone actually files games.
        makeApp("Games/Mac/Indie/2024/Stardew Valley.app")
        // 4. Past the depth ceiling — must NOT appear, or a deep scan becomes a disk crawl.
        makeApp("a/b/c/d/e/f/g/Too Deep.app")
        // 5. Inside a document bundle — a photo library's internals are not a game library.
        makeApp("Pictures.photoslibrary/resources/Fake.app")
        // 6. Volume housekeeping — pruned by name wherever it appears.
        makeApp(".Trashes/Deleted Game.app")
        makeApp("System/Internal.app")
        // 7. A Windows game folder: exe sits directly in it, title comes from the FOLDER.
        makeExe("Windows/Hollow Knight/hollow_knight.exe", bytes: 8192)
        // 8. A Windows game whose only exe is buried in layout folders — the title has to walk
        //    back up out of Binaries/Win64, or the library shows a game called "Win 64".
        makeExe("Windows/Fable Anniversary/Binaries/Win64/Fable.exe", bytes: 8192)
        // 9. A loose exe sitting in the chosen folder itself — one game each, as before.
        makeExe("Portal.exe", bytes: 8192)
        // 10. A Windows game filed under a folder that says "games live here" — the one Windows
        //     shape an UNTRUSTED (merely-plugged-in) drive is allowed to believe.
        makeExe("Games/Dead Cells/deadcells.exe", bytes: 8192)
        // 11. An ordinary work folder with an installer in it — the shape that turned into nine
        //     bogus library entries on a real backup drive. Absent either way: an untrusted walk
        //     won't call it a game at all, and even a trusted one won't, because bestExecutable
        //     throws out installer-shaped exe names (setup/unins/redist/...).
        makeExe("Departmental/setup_tool.exe", bytes: 8192)

        // Second half of the harness: the live machine. Whatever is actually mounted right now
        // gets listed with what the scanner makes of it — the synthetic tree can't tell us
        // whether a REAL volume is readable, enumerable, and in scope.
        log("[SCANTEST] --- mounted volumes ---")
        for volume in CustomSource.externalVolumes() {
            let excluded = CustomSource.isVolumeExcluded(volume.path)
            let started = Date()
            let found = excluded ? [] : CustomSource.debugScanFolder(volume, trusted: false)
            let elapsed = String(format: "%.2fs", Date().timeIntervalSince(started))
            log("[SCANTEST]   \(volume.path) '\(CustomSource.volumeName(volume))'"
                + (excluded ? " — excluded by user" : " → \(found.count) game(s) in \(elapsed)"))
            for g in found.prefix(10) { log("[SCANTEST]       \(g.title)") }
        }
        log("[SCANTEST] external scanning enabled: \(CustomSource.scanExternalDrives)")
        log("[SCANTEST] --- synthetic tree ---")

        let games = CustomSource.debugScanFolder(root, trusted: true)
        let titles = Set(games.map(\.title))
        let untrusted = Set(CustomSource.debugScanFolder(root, trusted: false).map(\.title))
        let hasBottle = CustomSource.defaultBottle() != nil

        log("[SCANTEST] ===== custom scan-folder walk =====")
        log("[SCANTEST] root: \(root.path)")
        log("[SCANTEST] CrossOver bottle available: \(hasBottle ? "yes — Windows cases live" : "no — Windows cases SKIP")")
        for g in games.sorted(by: { $0.title < $1.title }) {
            log("[SCANTEST]   found '\(g.title)'  [\(g.sourceBadgeTitle)]")
        }

        // (title, found when the user picked this folder, found when it's just a plugged-in
        //  drive, needs a CrossOver bottle to exist at all)
        let checks: [(String, Bool, Bool, Bool)] = [
            ("Thronefall",        true,  true,  false),
            ("Celeste",           true,  true,  false),
            ("Stardew Valley",    true,  true,  false),
            ("Too Deep",          false, false, false),
            ("Fake",              false, false, false),
            ("Deleted Game",      false, false, false),
            ("Internal",          false, false, false),
            ("Hollow Knight",     true,  false, true),
            ("Fable Anniversary", true,  false, true),
            ("Portal",            true,  false, true),
            ("Dead Cells",        true,  true,  true),
            ("Departmental",      false, false, true),
        ]

        var failures = 0, skipped = 0
        for (title, trustedExpected, untrustedExpected, needsCrossOver) in checks {
            if needsCrossOver, !hasBottle {
                skipped += 1
                log("[SCANTEST]   SKIP  '\(title)' (no CrossOver bottle to launch it with)")
                continue
            }
            for (mode, expected, actual) in [("picked folder", trustedExpected, titles.contains(title)),
                                             ("plugged-in drive", untrustedExpected, untrusted.contains(title))] {
                let ok = actual == expected
                if !ok { failures += 1 }
                log("[SCANTEST]   \(ok ? "PASS" : "FAIL")  '\(title)' as \(mode): expected \(expected ? "found" : "absent"), was \(actual ? "found" : "absent")")
            }
        }

        try? fm.removeItem(at: root)
        log("[SCANTEST] RESULT: \(failures == 0 ? "OK" : "\(failures) FAILURE(S)")\(skipped > 0 ? " (\(skipped) skipped)" : "")")
        log("[SCANTEST] ===== done =====")
        exit(failures == 0 ? 0 : 1)
    }

    // MARK: - File-size / launch-target spot check (MARQUEE_SIZECHECK)

    static func runSizeCheck(appState: AppState) {
        let games = appState.games
        Task { @MainActor in
            func log(_ s: String) { print(s); fflush(stdout) }
            log("[SIZECHECK] ===== \(games.count) games =====")
            for g in games {
                let (loc, size) = GameDetailsFetcher.debugLocationSize(for: g)
                log("[SIZECHECK] \(g.title)  [\(g.sourceBadgeTitle)]")
                log("[SIZECHECK]     size   = \(size)")
                log("[SIZECHECK]     loc    = \(loc)")
                log("[SIZECHECK]     launch = \(GameLauncher.debugLaunchTarget(g))")
            }
            log("[SIZECHECK] ===== done =====")
            exit(0)
        }
    }
}
