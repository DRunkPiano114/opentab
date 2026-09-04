# Changelog

What's new in each release of OpenTab, written for the people who use it.
Version headings and dates follow Keep a Changelog; categories are
New / Changed / Improved / Fixed / Security.

## [Unreleased]

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
