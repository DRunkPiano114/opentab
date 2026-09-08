<p align="center"><img src="docs/icon.png" width="128" alt=""></p>
<h1 align="center">OpenTab</h1>
<p align="center">Open source window and tab switcher for macOS.</p>

<p align="center"><img src="docs/demo.gif" width="800" alt="OpenTab in use"></p>

## Requirements

macOS 26 or later, Apple silicon.

## Install

1. Download `OpenTab-<version>.zip` from the [latest release](https://github.com/DRunkPiano114/opentab/releases/latest) and unzip it.
2. Drag `OpenTab.app` into Applications.
3. Open it. It is signed and notarized, so macOS asks once. The first-run guide handles permissions and your shortcut.

## Use

| Keys | Action |
|---|---|
| `⌘ Tab` | Open the list and step forward; release ⌘ to switch |
| `⇧ ⌘ Tab` | Same, stepping backward |
| `Enter` (in the list) or `⇧ ⌘ L` | Search by app, window title, tab title or address |
| `Right Arrow` / `Left Arrow` | Open a window's tabs in a side pane / go back |
| `⌘ W` (while searching) | Close the selected tab |
| `Escape` | Clear the search, leave the side pane, then dismiss |

## Build from source

Xcode 26 and [xcodegen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).

```bash
make build      # generate the project and build Debug into build/
make test       # OpenTabKit unit tests, no permissions needed
make test-app   # app-hosted tests; needs the Accessibility grant and drives the real UI
make run        # install to ~/Applications as "OpenTab Dev" and launch
```

Debug builds are signed with a self-signed certificate that `make build` creates on first use, so the Accessibility grant survives rebuilds.

The first `make build` after a clean checkout downloads Sparkle through Swift Package Manager, so it needs network once; `make test` never does.

## License

MIT. Copyright (c) 2026 Lingwei Wu.
