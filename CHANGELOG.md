# Changelog

What's new in each release of OpenTab, written for the people who use it.
Version headings and dates follow Keep a Changelog; categories are
New / Changed / Improved / Fixed / Security.

## [Unreleased]

## [0.1.0] - 2026-09-XX

**The first release: one list for every window and every tab, on Option-Tab.**

### New

- Hold Option and tap Tab to walk a single list of every open window, and let go of Option to switch to the one you landed on.
- Option-Shift-Tab opens the same list running backwards, from the bottom.
- Press Return while the list is open, or Command-Shift-L from anywhere, to search it by app name, window title, tab title or web address.
- Search matches loosely rather than literally, so a few characters in the right order are enough to find a window.
- Chinese titles answer to their characters, to full pinyin and to pinyin initials, so "wj" finds 文件.
- Windows on other Spaces and in full screen are listed like any other, and picking one takes you to it.
- Safari and the Chrome family — Chrome, Edge, Brave and other Chromium browsers — list their open tabs next to their windows.
- Finder tabs, terminal tabs and the tabs of any other app that uses native tabs are listed too.
- Press the right arrow on a window to open its tabs in a second pane, each with its favicon, and search inside just that window; the left arrow or Escape brings you back.
- Press Command-W while searching to close the tab you have selected without leaving the list.
- Settings covers where the panel appears, its text size and width, whether the list is ordered by recency or alphabetically, the three shortcuts, and a list of title patterns to keep out of the list.
- Turn on "Open OpenTab at login" in Settings to have it running after every restart.
- OpenTab can replace the system Command-Tab switcher with its own list; this is off until you turn it on, and the system switcher comes back when OpenTab quits.
- Private and incognito windows are left out of the list until you ask for them in Privacy.
- A menu bar icon shows the state of OpenTab's permissions and gets you to Settings; you can hide it once you no longer need it.
- On first launch OpenTab offers to move itself into your Applications folder, which is what keeps your Accessibility permission from being forgotten, and then explains what it needs before macOS asks for anything.
- OpenTab requires macOS 26 or later.
