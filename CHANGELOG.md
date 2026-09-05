# Changelog

What's new in each release of OpenTab, written for the people who use it.
Version headings and dates follow Keep a Changelog; categories are
New / Changed / Improved / Fixed / Security.

## [Unreleased]

## [0.3.0] - 2026-09-05

### New

- The first-run guide asks which shortcut you want. Choosing Command-Tab turns on "Open OpenTab at login" with it, so a crash cannot leave you without an app switcher until the next login.
- Every shortcut field has a × that puts its default back.

### Changed

- Command-Tab opens OpenTab by default, including on existing installs that never changed the shortcut; the system app switcher comes back when OpenTab quits. Option-Tab is one click away in Settings › Shortcuts, is offered at first run, and OpenTab falls back to it on its own before Accessibility is granted, while another copy of OpenTab is running, and on a Mac where Command-Tab cannot be taken over. An install where you chose Option-Tab yourself keeps it.
- The menu bar menu is a short list of actions: Open Switcher, Search Windows, Rebuild Index, Check for Updates…, About OpenTab, Settings… and Quit OpenTab. A single attention row appears at the top only when something needs fixing, and the menu bar icon carries an orange dot while it is there.
- Settings has four tabs, General, Shortcuts, Privacy and About. About holds the version, the update controls and the memory and uptime line.
- Shortcuts are written with the key's name, "⌘ Tab" rather than "⌘⇥", everywhere OpenTab shows one.

### Fixed

- The search shortcut can no longer be set to Command-Tab, which registered and never fired.
- A shortcut already used by one of OpenTab's other fields is refused when you record it.
- Turning Accessibility off while OpenTab is running gives the system Command-Tab back at once.

## [0.2.0] - 2026-09-05

### New

- OpenTab checks for a newer version once a day and offers to install it with one click; the check tells GitHub your IP address, OpenTab's name and version, and nothing about you or your windows. Turn it off under Settings › General, or check by hand with "Check for Updates…" from the menu bar icon.

## [0.1.1] - 2026-09-05

### New

- OpenTab warns you, once at launch and in Settings, when another copy of it is running: both copies answer the shortcut, so every press would open two switchers.

## [0.1.0] - 2026-09-04

**Every window and every tab in one list, on Option-Tab.**

### New

- Hold Option and tap Tab to walk through every open window; let go to switch. Option-Shift-Tab walks backwards.
- Press Return in the list, or Command-Shift-L anywhere, to search by app, window title, tab title or address.
- Search is forgiving: a few characters in the right order are enough. Chinese titles match by character, full pinyin or initials, so "wj" finds 文件.
- Windows on other Spaces and in full screen are listed and reachable like any other.
- Safari, Chrome, Edge, Brave and other Chromium browsers list their tabs alongside their windows.
- Finder, Ghostty and iTerm2 tabs are listed too, as are the tabs of other apps that use native macOS tabs.
- Right arrow opens a window's tabs in a side pane with favicons. While searching, Command-W closes the selected tab.
- Private and incognito windows stay out of the list unless you opt in under Settings › Privacy.
- Settings: panel position, text size and width, sort by recency or name, the three shortcuts, open at login, and title patterns to hide.
- Optional: let OpenTab take over the system Command-Tab. Off by default; the system switcher returns when OpenTab quits.
- On first launch OpenTab offers to move itself into Applications so the Accessibility permission you grant keeps working, then walks you through the permissions it needs.
