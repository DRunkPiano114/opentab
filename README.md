# OpenTab

Command-Tab window and tab switcher for macOS. Hold Command, tap Tab, and every open window and every browser tab is in one list, searchable in English, Chinese or pinyin.

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
6. From then on OpenTab checks once a day for a newer version and offers to install it with one click. Turn that off under Settings › About if you would rather update by hand from the release page.

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

**Settings** (from the menu bar icon) has four tabs: General (open at login, menu bar icon, panel position, text size and width, sort order, title patterns to hide), Shortcuts (the three shortcuts; a shortcut field's × puts its default back), Privacy (private windows, icons, permissions), About (version, updates, a link to this page, memory and uptime).

**Command-Tab** opens OpenTab instead of the system app switcher while OpenTab runs, and the system switcher comes back when OpenTab quits. If OpenTab is force quit and Command-Tab stays dead, the next launch of OpenTab puts it back, or you can put it back right away with:

```bash
/Applications/OpenTab.app/Contents/MacOS/OpenTab --restore-cmd-tab
```

Launching OpenTab with `--disable-cmd-tab-takeover` makes it behave as if the takeover were unavailable, which is how the Option-Tab fallback can be tried on a Mac that supports Command-Tab.

Where the takeover is unavailable, before you grant Accessibility, or while another copy of OpenTab is running, OpenTab uses Option-Tab instead and says so in Settings and in the menu bar.

## Privacy

- No telemetry. OpenTab sends nothing about you or your windows anywhere, and its logs and diagnostic dumps never contain window titles.
- Once a day OpenTab asks GitHub whether a newer version exists. That request carries your IP address, OpenTab's name and version, and nothing about you or your windows. An update is shown to you and installs when you click Install; the first update alert also offers a box to install future updates automatically, which stays unticked unless you tick it. Switch the check off under Settings › About, or check by hand with "Check for Updates…" from the menu bar icon. The only other network request is the optional "Look up missing icons on Google" under Settings › Privacy, which stays off until you turn it on; with it on, the domain of each tab is sent to Google to fetch a favicon.
- Private and incognito windows are left out of the list unless you opt in under Settings › Privacy. Safari exposes no private-window flag to other apps, so with the opt-in off Safari is listed by window and never by tab.

## How it works

Windows come from the Accessibility API. Browser tabs come from AppleScript, which is why the Automation permission is needed per browser. Windows on other Spaces and in full screen are reached through undocumented window-server interfaces; when those are unavailable OpenTab degrades to listing the current Space only.

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

## Releasing

1. Write the new version's section in `CHANGELOG.md` and push it to `main`.
2. Quit every running copy of OpenTab, then `make tag VERSION=x.y.z`. It runs every check and both test suites before it creates the annotated tag, and refuses to tag if any of them fails.
3. `git push origin vx.y.z`.

Release builds are signed with a Developer ID and notarized by `Scripts/release.sh`. Pushing the `v*` tag runs that script in GitHub Actions, which publishes the release with the matching section of `CHANGELOG.md` as its notes. The workflow also signs the zip with the project's Sparkle key and publishes `appcast.xml` next to it, which is what installed copies read to find the update.

## License

MIT. Copyright (c) 2026 Lingwei Wu.
