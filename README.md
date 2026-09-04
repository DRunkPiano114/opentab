# OpenTab

Option-Tab window and tab switcher for macOS. Hold Option, tap Tab, and every open window and every browser tab is in one list, searchable in English, Chinese or pinyin.

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

## Use

| Keys | Action |
|---|---|
| Option-Tab | Open the list and step forward; release Option to switch |
| Option-Shift-Tab | Same, stepping backward |
| Return (in the list) or Command-Shift-L | Search by app, window title, tab title or address |
| Right arrow / Left arrow | Open a window's tabs in a side pane / go back |
| Command-W (while searching) | Close the selected tab |
| Escape | Clear the search, leave the side pane, then dismiss |

Search is forgiving: a few characters in the right order match. Chinese titles match by character, by full pinyin or by initials.

**Settings** (from the menu bar icon) cover panel position, text size and width, sort order, the three shortcuts, launch at login, title patterns to hide, and privacy.

**Command-Tab takeover** is optional and off by default. When on, Command-Tab opens OpenTab instead of the system switcher; the system switcher comes back when OpenTab quits. If OpenTab is ever killed while the takeover is on and Command-Tab stays dead, run:

```bash
/Applications/OpenTab.app/Contents/MacOS/OpenTab --restore-cmd-tab
```

## Privacy

- No telemetry and no automatic updates. OpenTab makes no network request unless you turn on "Look up missing icons on Google" under Settings › Privacy, which is off by default; with it on, the domain of each tab is sent to Google to fetch a favicon.
- Private and incognito windows are left out of the list unless you opt in under Settings › Privacy. Safari exposes no private-window flag to other apps, so with the opt-in off Safari is listed by window and never by tab.
- Logs and diagnostic dumps never contain window titles.

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

Debug builds are signed with a self-signed certificate that `make build` creates on first use, so the Accessibility grant survives rebuilds. Release builds are signed with a Developer ID and notarized by `Scripts/release.sh`; a `v*` tag runs that script in GitHub Actions and publishes the release with the matching section of `CHANGELOG.md` as its notes.

## License

MIT. Copyright (c) 2026 Lingwei Wu.
