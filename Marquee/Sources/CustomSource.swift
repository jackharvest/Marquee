import Foundation
import AppKit

// User-curated library entries — the escape hatch for anything the automatic scanners can't
// know about: games on an external drive, a network share, or a jump drive with a user-invented
// layout ("scan folders"), and individually added apps/exes, including non-games people want
// couch-launchable (Plex, Jellyfin, a streaming app) — added via drag & drop onto the window or
// Library ▸ Add Game…. Both lists persist in UserDefaults; scan() re-reads them every library
// refresh, so a yanked jump drive's games simply drop out of the scan (and return when it's
// plugged back in) without ever touching the saved entries.
//
// External drives are scanned WITHOUT being added by hand: every mounted
// non-internal volume counts as an implicit scan folder unless the user excludes it, and a
// drive plugged in later triggers a refresh on its own (AppState.installVolumeObserver). A
// user whose games all live on an external disk should never have to discover that pointing
// Marquee at the drive was an option in the first place.

// One individually-added game. `bottle` is only set for Windows .exe entries — they launch
// through CrossOver exactly like a scanned bottle game (`wine --bottle {bottle} {exe}` takes
// any unix path, the exe doesn't have to live inside the bottle).
struct CustomGameEntry: Codable, Equatable, Identifiable {
    var path: String
    var bottle: String?

    var id: String { path }
    var url: URL { URL(fileURLWithPath: path) }
    var isExe: Bool { path.lowercased().hasSuffix(".exe") }
}

struct CustomSource {
    private static let foldersKey  = "customScanFolders"
    private static let gamesKey    = "customGameEntries"
    private static let externalKey = "scanExternalDrives"
    private static let excludedKey = "excludedVolumePaths"

    private static let iconCacheDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Marquee/CustomIcons")

    // MARK: - Persisted lists

    static var scanFolders: [String] {
        UserDefaults.standard.stringArray(forKey: foldersKey) ?? []
    }

    static var gameEntries: [CustomGameEntry] {
        guard let data = UserDefaults.standard.data(forKey: gamesKey),
              let entries = try? JSONDecoder().decode([CustomGameEntry].self, from: data)
        else { return [] }
        return entries
    }

    @discardableResult
    static func addScanFolder(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        var folders = scanFolders
        guard !folders.contains(path) else { return false }
        folders.append(path)
        UserDefaults.standard.set(folders, forKey: foldersKey)
        return true
    }

    static func removeScanFolder(_ path: String) {
        UserDefaults.standard.set(scanFolders.filter { $0 != path }, forKey: foldersKey)
    }

    @discardableResult
    static func addGameEntry(_ entry: CustomGameEntry) -> Bool {
        var entries = gameEntries
        guard !entries.contains(where: { $0.path == entry.path }) else { return false }
        entries.append(entry)
        persist(entries)
        return true
    }

    static func removeGameEntry(_ entry: CustomGameEntry) {
        persist(gameEntries.filter { $0.path != entry.path })
    }

    static func updateGameEntry(_ entry: CustomGameEntry) {
        var entries = gameEntries
        guard let idx = entries.firstIndex(where: { $0.path == entry.path }) else { return }
        entries[idx] = entry
        persist(entries)
    }

    private static func persist(_ entries: [CustomGameEntry]) {
        if let data = try? JSONEncoder().encode(entries) {
            UserDefaults.standard.set(data, forKey: gamesKey)
        }
    }

    // MARK: - External drives

    // On by default: the whole point is that plugging a game drive in is enough. Every scan is
    // bounded (see `dirBudget`/`maxDepth`), so a huge or slow disk can't stall a refresh.
    static var scanExternalDrives: Bool {
        UserDefaults.standard.object(forKey: externalKey) == nil
            ? true : UserDefaults.standard.bool(forKey: externalKey)
    }

    static func setScanExternalDrives(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: externalKey)
    }

    // Per-drive opt-out, by mount path — a Time Machine disk or a media library has no games
    // on it and shouldn't be walked every refresh.
    static var excludedVolumes: [String] {
        UserDefaults.standard.stringArray(forKey: excludedKey) ?? []
    }

    static func setVolumeExcluded(_ path: String, excluded: Bool) {
        var list = excludedVolumes.filter { $0 != path }
        if excluded { list.append(path) }
        UserDefaults.standard.set(list, forKey: excludedKey)
    }

    static func isVolumeExcluded(_ path: String) -> Bool { excludedVolumes.contains(path) }

    // What the last scan of each auto-scanned volume actually turned up, so Preferences can say
    // "no games found" instead of leaving the user to guess. A general-purpose drive (a backup
    // disk, a media archive) costs a few seconds of every library refresh and finds nothing —
    // worth knowing, since switching it off is one toggle away in the same row.
    private static let resultsKey = "volumeScanResults"

    static func volumeScanResult(_ path: String) -> Int? {
        (UserDefaults.standard.dictionary(forKey: resultsKey)?[path] as? NSNumber)?.intValue
    }

    private static func recordVolumeScan(_ path: String, found: Int) {
        var results = UserDefaults.standard.dictionary(forKey: resultsKey) ?? [:]
        results[path] = found
        // Volumes that haven't been seen in a long time shouldn't accumulate forever; a mount
        // path is reused across drives, so a stale entry is worse than none.
        let live = Set(externalVolumes().map(\.path))
        results = results.filter { live.contains($0.key) }
        UserDefaults.standard.set(results, forKey: resultsKey)
    }

    // Every mounted volume that isn't the boot disk: USB/Thunderbolt drives, SD cards, network
    // shares, mounted images. The filter is "not explicitly internal" rather than "explicitly
    // external" because `volumeIsInternal` is nil for network mounts — a NAS full of games is
    // exactly the case this exists for.
    static func externalVolumes() -> [URL] {
        let keys: Set<URLResourceKey> = [.volumeIsInternalKey, .volumeIsBrowsableKey,
                                         .volumeIsRootFileSystemKey, .volumeNameKey]
        guard let volumes = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: Array(keys), options: [.skipHiddenVolumes])
        else { return [] }

        return volumes.filter { url in
            guard let rv = try? url.resourceValues(forKeys: keys) else { return false }
            if rv.volumeIsRootFileSystem == true { return false }
            if rv.volumeIsBrowsable == false { return false }
            if rv.volumeIsInternal == true { return false }
            return true
        }
    }

    static func volumeName(_ url: URL) -> String {
        (try? url.resourceValues(forKeys: [.volumeNameKey]))?.volumeName
            ?? url.lastPathComponent
    }

    // MARK: - Scan

    static func scan() -> [Game] {
        var games: [Game] = []

        for entry in gameEntries where FileManager.default.fileExists(atPath: entry.path) {
            if entry.isExe {
                if let bottle = entry.bottle ?? defaultBottle() {
                    games.append(exeGame(exePath: entry.path, bottle: bottle))
                }
            } else if entry.path.hasSuffix(".app") {
                if let game = appGame(at: entry.url) { games.append(game) }
            }
        }

        // A hand-picked folder is a statement ("my games live here") and gets the patient,
        // permissive walk. A mounted drive is a guess on Marquee's part and gets the cautious
        // one — see ScanContext.
        for folder in scanFolders {
            games += scanFolder(URL(fileURLWithPath: folder), trusted: true)
        }
        for volume in autoScanVolumes() {
            let found = scanFolder(volume, trusted: false)
            recordVolumeScan(volume.path, found: found.count)
            games += found
        }

        // A hand-added folder living on an auto-scanned drive (or two folders that overlap)
        // would otherwise report the same game twice. Game.id is derived from source identity,
        // so first-one-wins dedupe is exact.
        var seen = Set<UUID>()
        return games.filter { seen.insert($0.id).inserted }
    }

    // Mounted external volumes in scope: external scanning on, not excluded by the user, and
    // not already covered by (inside, or containing) a hand-picked scan folder.
    private static func autoScanVolumes() -> [URL] {
        guard scanExternalDrives else { return [] }
        let excluded = Set(excludedVolumes)
        let folders = scanFolders
        return externalVolumes().filter { volume in
            guard !excluded.contains(volume.path) else { return false }
            return !folders.contains { volume.path == $0 || volume.path.hasPrefix($0 + "/") }
        }
    }

    // What a single walk is allowed to spend, and how much it's allowed to assume.
    //
    // `trusted` is the whole distinction between the two kinds of scan root. A folder the user
    // picked is worth being thorough in. A drive that merely happens to be plugged in is not:
    // it may be a backup disk, a work archive, or a media library, and it may be slow. Both of
    // those turned out to matter — a live run against a real 2TB general-purpose backup drive
    // took over three minutes and produced nine "games" named Desktop, Software, U, V and the
    // like, because on a drive that isn't dedicated to games almost every top-level folder has
    // some .exe buried in it. An untrusted walk is therefore shallower, cheaper, deadlined, and
    // only believes in a Windows game when something in the path says "games live here"
    // (a Games/ or SteamLibrary/ folder, or a drive named for them). Mac .app bundles are
    // exempt from that last rule in both modes: a .app is an unambiguous marker and costs a
    // single directory listing to spot, so there's nothing to be cautious about.
    private final class ScanContext {
        let root: URL
        let trusted: Bool
        let maxDepth: Int
        let deadline: Date
        var budget: Int

        init(root: URL, trusted: Bool) {
            self.root     = root
            self.trusted  = trusted
            self.maxDepth = trusted ? 5 : 4
            self.budget   = trusted ? 6000 : 2500
            self.deadline = Date().addingTimeInterval(trusted ? 20 : 6)
        }

        // Directory listings on a slow or sleeping USB disk are the unpredictable cost here,
        // so the walk is bounded by wall-clock time as well as by directory count — a library
        // refresh can't be allowed to hang on hardware Marquee knows nothing about.
        var exhausted: Bool { budget <= 0 || Date() > deadline }
    }

    // Directory names that never hold games, pruned wherever they appear. Everything here is
    // either an OS/volume housekeeping directory or a backup store.
    private static let skippedNames: Set<String> = [
        "Library", "System", "private", "usr", "sbin", "dev", "cores", "Volumes",
        "Backups.backupdb", "System Volume Information", "$RECYCLE.BIN", "MSOCache",
        "node_modules", ".Trashes", ".Spotlight-V100", ".fseventsd", ".TemporaryItems",
        "TheVolumeSettingsFolder", "Recovery",
    ]

    // Directories macOS presents as single documents/bundles — walking into them finds nothing
    // but a game's own internals (or a photo library's thousands of files).
    private static let bundleExtensions: Set<String> = [
        "app", "framework", "bundle", "plugin", "kext", "xpc", "prefpane", "qlgenerator",
        "mdimporter", "saver", "component", "wdgt", "dsym", "pkg", "mpkg", "rtfd", "scptd",
        "photoslibrary", "fcpbundle", "musiclibrary", "tvlibrary", "aplibrary", "logicx",
        "sparsebundle", "download", "appdownload", "lrdata", "imovielibrary", "theater",
    ]

    // Folder names that describe a game's layout rather than the game — a game found in
    // Foo/Binaries/Win64 is "Foo", not "Win64". Titles are the only naming signal a custom
    // location gives us, and they're what art lookups match on, so getting this right matters
    // more here than anywhere else in the scanners.
    private static let genericFolderNames: Set<String> = [
        "bin", "bin32", "bin64", "binaries", "win", "win32", "win64", "windows", "x64", "x86",
        "32bit", "64bit", "game", "games", "app", "application", "data", "build", "release",
        "retail", "content", "contents", "files", "program", "programs", "exe", "launcher",
        "install", "installed", "redist", "steamapps", "common",
    ]

    // "Somewhere in this path, someone filed things as games" — what an untrusted walk needs to
    // see before it will call a folder full of .exe files a game.
    private static let gameLibraryFolderNames: Set<String> = [
        "steam", "steamlibrary", "steamapps", "common", "gog", "gog galaxy", "epic",
        "epic games", "crossover", "bottles", "wine", "emulation", "roms", "program files",
        "program files (x86)",
    ]

    private static func isGameLibraryName(_ name: String) -> Bool {
        let lower = name.lowercased()
        return lower.contains("game") || gameLibraryFolderNames.contains(lower)
    }

    private static func scanFolder(_ folder: URL, trusted: Bool) -> [Game] {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDir),
              isDir.boolValue else { return [] }
        let context = ScanContext(root: folder, trusted: trusted)
        // A drive named "Games" (or a folder the user picked by hand) vouches for everything
        // inside it, so the Windows rule applies from the root down.
        let vouched = trusted || isGameLibraryName(volumeName(folder))
            || isGameLibraryName(folder.lastPathComponent)
        return scanDirectory(folder, depth: 0, gameLibrary: vouched, context: context)
    }

    // Debug entry point for SelfTests (MARQUEE_SCANTEST): one walk, against a folder the
    // harness builds, with no UserDefaults or mounted drives involved.
    static func debugScanFolder(_ folder: URL, trusted: Bool = true) -> [Game] {
        scanFolder(folder, trusted: trusted)
    }

    // A user-chosen location is scanned on its own terms — the user pointed at it and said "my
    // games live here", so unlike /Applications there's no category allowlist. Each directory is
    // classified as one of three things:
    //
    //   • .app bundles at this level      → one game each (never walked into)
    //   • at least one .exe at this level → THIS folder is one Windows game (leaf; its data
    //                                       directories are not worth walking)
    //   • neither                         → a container: recurse, up to maxDepth
    //
    // The scan root itself is the exception: loose .exe files sitting directly in it stay one
    // game each, matching how "a folder of exes" was handled before deep scanning existed.
    //
    // Note what ISN'T here: "this folder has an exe SOMEWHERE under it, so call the folder a
    // game." That rule existed briefly and was dropped after the live backup-drive run described
    // on ScanContext. Walking up out of layout folders (see `gameTitle`) covers the case it was
    // meant for: Foo/Binaries/Win64/Foo.exe is still found, and still titled "Foo".
    //
    // Windows finds are skipped entirely when CrossOver has no bottles — an entry that can
    // never launch is worse than an absent one.
    private static func scanDirectory(_ dir: URL, depth: Int,
                                      gameLibrary: Bool, context: ScanContext) -> [Game] {
        guard !context.exhausted else { return [] }
        context.budget -= 1

        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
        else { return [] }

        var games: [Game] = []
        var subdirs: [URL] = []
        var hasLooseExe = false
        var looseExes: [URL] = []
        let bottle = defaultBottle()

        for entry in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let ext = entry.pathExtension.lowercased()
            let isDirectory = (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true

            if ext == "app" {
                if let game = appGame(at: entry) { games.append(game) }
            } else if ext == "exe", !isDirectory {
                hasLooseExe = true
                looseExes.append(entry)
            } else if isDirectory,
                      !bundleExtensions.contains(ext),
                      !skippedNames.contains(entry.lastPathComponent) {
                subdirs.append(entry)
            }
        }

        // Windows games are only believed where the walk is allowed to believe them.
        if hasLooseExe, let bottle, context.trusted || gameLibrary {
            if depth == 0 {
                games += looseExes.map { exeGame(exePath: $0.path, bottle: bottle) }
            } else {
                // This folder IS the game. bestExecutable picks the real launcher out of the
                // installers/redists/tools that ship next to it.
                let title = gameTitle(for: dir, root: context.root)
                if let exe = GameLauncher.bestExecutable(in: dir, title: title) {
                    games.append(exeGame(exePath: exe.path, bottle: bottle, title: title))
                }
                return games   // leaf — don't walk a game's own data directories
            }
        } else if hasLooseExe, depth > 0 {
            return games       // an exe folder on an untrusted drive: not a game, not a container
        }

        if depth < context.maxDepth {
            for sub in subdirs {
                guard !context.exhausted else { break }
                games += scanDirectory(sub, depth: depth + 1,
                                       gameLibrary: gameLibrary || isGameLibraryName(sub.lastPathComponent),
                                       context: context)
            }
        }
        return games
    }

    // Walks up out of layout folders ("Foo/Binaries/Win64" → "Foo"), never past the scan root.
    private static func gameTitle(for dir: URL, root: URL) -> String {
        var url = dir
        while genericFolderNames.contains(url.lastPathComponent.lowercased()),
              url.standardizedFileURL.path != root.standardizedFileURL.path {
            let parent = url.deletingLastPathComponent()
            guard parent.path.count >= root.standardizedFileURL.path.count else { break }
            url = parent
        }
        return prettyTitle(from: url.lastPathComponent)
    }

    // MARK: - Game construction

    private static func appGame(at bundleURL: URL) -> Game? {
        let plist = NSDictionary(contentsOf: bundleURL.appendingPathComponent("Contents/Info.plist"))
        let title = (plist?["CFBundleDisplayName"] as? String)
            ?? (plist?["CFBundleName"] as? String)
            ?? bundleURL.deletingPathExtension().lastPathComponent
        let iconPath = extractAndCacheIcon(
            appURL: bundleURL, key: plist?["CFBundleIdentifier"] as? String)
        return Game(
            title: title,
            source: .applications(bundleURL: bundleURL),
            metadata: GameMetadata(bundledIconPath: iconPath)
        )
    }

    private static func exeGame(exePath: String, bottle: String, title: String? = nil) -> Game {
        let name = title ?? prettyTitle(
            from: (exePath as NSString).lastPathComponent.replacingOccurrences(of: ".exe", with: ""))
        return Game(title: name, source: .crossOver(bottleName: bottle, exePath: exePath))
    }

    // First bottle alphabetically = the launch default for exes added without an explicit
    // bottle choice (Settings' Added Games list offers a per-entry picker when there's more
    // than one). nil when CrossOver isn't installed or has no bottles.
    static func defaultBottle() -> String? {
        CrossOverSource.availableBottles().first
    }

    // "RuneFactory_5" / "StardewValley" / "half.life.2" → a readable title. Folder/exe names
    // are the only naming signal a custom location has.
    static func prettyTitle(from raw: String) -> String {
        var s = raw
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: ".", with: " ")
            .replacingOccurrences(of: "-", with: " ")
        var out = ""
        for (i, c) in s.enumerated() {
            if i > 0, c.isUppercase {
                let prev = s[s.index(s.startIndex, offsetBy: i - 1)]
                if prev.isLowercase || prev.isNumber { out.append(" ") }
            }
            out.append(c)
        }
        s = out.components(separatedBy: .whitespaces).filter { !$0.isEmpty }.joined(separator: " ")
        return s.isEmpty ? raw : s
    }

    // Same icon-fallback pattern as ApplicationsSource/EpicSource: the bundle's own icon,
    // cached once as a PNG, feeds ArtFetcher's bundledIconPath tier when no Steam match
    // exists — which for a Plex/Jellyfin-style non-game is the common case, and their own
    // icon is exactly the right poster.
    private static func extractAndCacheIcon(appURL: URL, key: String?) -> URL? {
        let name = key ?? appURL.path.replacingOccurrences(of: "/", with: "_")
        let dest = iconCacheDir.appendingPathComponent("\(name).png")
        if FileManager.default.fileExists(atPath: dest.path) { return dest }

        let icon = NSWorkspace.shared.icon(forFile: appURL.path)
        guard let tiff = icon.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:])
        else { return nil }

        try? FileManager.default.createDirectory(at: iconCacheDir, withIntermediateDirectories: true)
        guard (try? png.write(to: dest)) != nil else { return nil }
        return dest
    }
}
