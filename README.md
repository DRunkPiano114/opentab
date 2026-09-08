# OpenTab

Command-Tab window and tab switcher for macOS. Hold Command, tap Tab, and every open window and every browser tab is in one list, searchable in English, Chinese or pinyin.

![OpenTab in use](docs/demo.gif)

## Requirements

- macOS 26 or later
- Apple silicon

## Install

1. Download `OpenTab-<version>.zip` from the [latest release](https://github.com/DRunkPiano114/opentab/releases/latest) and unzip it.
2. Drag `OpenTab.app` into your Applications folder. If you launch it from Downloads instead, OpenTab offers to move itself; say yes, because macOS ties the Accessibility permission to where the app lives.
3. Open it. The download is signed and notarized, so macOS only asks once whether you want to open an app from the internet.
4. Grant the two permissions the first-run guide asks for:
   - **Accessibility** is required. It is how OpenTab lists windows and brings the one you pick to the front.
   - **Automation** is asked per browser, the first time OpenTab lists that browser's tabs. Declining it for a browser only removes that browser's tabs from the list; its windows stay.
5. Choose your shortcut when the guide asks for it: Command-Tab, which is the default and turns on "Open OpenTab at login" along with it, or Option-Tab.

From then on OpenTab checks once a day for a newer version and offers to install it with one click. Turn that off under Settings › About if you would rather update by hand from the release page.

## Use

| Keys | Action |
|---|---|
| `⌘ Tab` | Open the list and step forward; release ⌘ to switch |
| `⇧ ⌘ Tab` | Same, stepping backward |
| `⌥ Tab` / `⇧ ⌥ Tab` | The same two actions when OpenTab is set to Option-Tab |
| `Enter` (in the list) or `⇧ ⌘ L` | Search by app, window title, tab title or address |
| `Right Arrow` / `Left Arrow` | Open a window's tabs in a side pane / go back |
| `⌘ W` (while searching) | Close the selected tab |
| `Escape` | Clear the search, leave the side pane, then dismiss |

Search is forgiving: a few characters in the right order match. Chinese titles match by character, by full pinyin or by initials.

**Settings** (from the menu bar icon) has four tabs: General (open at login, menu bar icon, panel position, text size and width, sort order), Shortcuts (the three shortcuts; a shortcut field's × puts its default back), Privacy (private windows, icons, permissions), About (version, updates, a link to this page, memory and uptime).

**Command-Tab** opens OpenTab instead of the system app switcher while OpenTab runs, and the system switcher comes back when OpenTab quits. If OpenTab is force quit and Command-Tab stays dead, the next launch of OpenTab puts it back, or you can put it back right away with:

```bash
/Applications/OpenTab.app/Contents/MacOS/OpenTab --restore-cmd-tab
```

Where the takeover is unavailable, before you grant Accessibility, or while another copy of OpenTab is running, OpenTab uses Option-Tab instead and says so in Settings and in the menu bar.

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
