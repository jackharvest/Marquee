<p align="center">
  <img src="assets/images/Marquee-logo-icon_128.png" alt="Marquee logo" width="110">
</p>

<h1 align="center">Marquee</h1>

<p align="center"><strong>All your Mac games on one shelf.</strong><br>
A console-style game launcher for macOS that finds every game you own — CrossOver, Steam, Epic, GOG, and the Mac App Store — and puts them in one beautiful, couch-friendly library.</p>

![Marquee's 3D carousel](docs/screenshots/hero-carousel.jpg)

<p align="center"><a href="https://jackharvest.com/Marquee">jackharvest.com/Marquee</a></p>

## Why

Games on a Mac end up scattered across half a dozen launchers: native titles, Steam, Epic, GOG, and
Windows games running through CrossOver. Marquee scans all of it automatically into one shelf you
browse, search, and play from — no manual list-building, ever.

**→ Full feature tour, more screenshots, and the download: [jackharvest.com/Marquee](https://jackharvest.com/Marquee)**

|  |  |
|---|---|
| ![The carousel, in motion](docs/screenshots/carousel.gif) | ![Rainbow Slide, in motion](docs/screenshots/rainbow-slide-motion.gif) |
| *The carousel — real spring physics, not a slideshow* | *Rainbow Slide — a Wii Menu-style wheel of covers* |

## Highlights

- **Seven view modes** — Carousel, Rainbow Slide, Big, Grid, Wall, List, Compact List — ⌘1–7
- **Every store, found automatically** — CrossOver, Steam, Epic, GOG, Mac App Store, no manual entry
- **Games on an external drive? Just plug it in** — mounted drives are scanned automatically, and a drive connected while Marquee is open refreshes the library on the spot
- **Bring your own library** — drag any app or exe onto the window (Plex, emulators, anything) and remove it just as easily
- **Yours to switch off** — the music player and the hold-to-launch PLAY button are both optional (Settings ▸ Music / Behavior)
- **A console-style pause menu** — every setting, zero menu bar, controller-first
- **Boots like a console** — Launch at Login + Start in Full Screen, couch-ready
- **Updates itself** — checks its own GitHub releases and installs in place, no terminal required
- **Real playtime tracking, smart sort, live search, cover art that looks right, an ambient music player** — the small stuff, done

| | | |
|---|---|---|
| ![Grid view](docs/screenshots/grid-view.jpg) | ![Compact List view](docs/screenshots/compact-list.jpg) | ![Couch Mode pause menu](docs/screenshots/couch-mode.jpg) |
| ![List view](docs/screenshots/list-view.jpg) | ![Search and sort](docs/screenshots/search-sort.jpg) | ![Detail page](docs/screenshots/detail-view.jpg) |

## Getting started

Mac only, Apple Silicon — Marquee exists to fill the hole [Playnite](https://playnite.link) leaves on
the Mac. Grab the latest [release](https://github.com/jackharvest/Marquee/releases/latest): open the
`.dmg` and drag `Marquee` into `Applications`, or build from source:

```bash
git clone https://github.com/jackharvest/Marquee.git
cd Marquee
make run     # builds Marquee.app and opens it
```

Requires macOS 14+; building needs a Swift 5.9+ toolchain (no Xcode project). First launch walks you
through a short setup — everything's changeable later in Settings (⌘,).

Gatekeeper may flag a downloaded (not self-built) copy as unnotarized — right-click → Open → Open once,
and it launches normally forever after. After that first launch, Marquee checks for and installs its
own updates, so you shouldn't need to come back here again.

## Couch mode

Pair a controller, flip on **Start in Full Screen** + **Launch at Login** in the pause menu, and set
the Mac to auto-login — power it on and it lands straight in your fullscreen library, no keyboard
needed. Full HDMI/AirPlay setup notes are on the [website](https://jackharvest.com/Marquee).

## Where games come from

CrossOver bottles, native Steam, Epic, GOG, and Mac App Store games — each detected its own way (Start
Menu shortcuts, `.acf` manifests, bundle markers). Every connected external drive is scanned too, and
any drive can be skipped individually in **Settings ▸ Custom Library ▸ External Drives**.

Games somewhere else entirely? Point Marquee at the folder your game `.app` files actually live in —
**Add Games Folder…** on the empty-library screen, **Library ▸ Add Folder to Scan…**, or just drop the
folder onto the window. Folders you pick are searched several levels deep, so a shelf like
`Games/Mac/Indie/…` works as-is. Details on the [website](https://jackharvest.com/Marquee/features.html).

## Privacy

Marquee is private by design, and the first-launch flow spells this out before asking anything of you:

- **Reads your game libraries** — the folders above, read-only, to find installed games.
- **Writes only its own files** — cover art cache and settings live in your user Library folder. Marquee never modifies games or other apps.
- **Goes online only for cover art** — Steam's public listings or SteamGridDB, your choice. No account required, no analytics, no tracking, ever.
- **No macOS permissions required** — Marquee never prompts for privacy access. If macOS ever mentions app changes when a CrossOver game launches, that's CrossOver tidying its own generated shortcuts (Marquee launches wine with its responsibility disclaimed so the OS attributes that housekeeping correctly — and denying it is harmless either way).

## Support

If Marquee makes your Mac gaming life nicer, you can [buy me a coffee](https://www.buymeacoffee.com/jackharvest) ☕ — and prove my wife wrong.

## License

[MIT](LICENSE)
