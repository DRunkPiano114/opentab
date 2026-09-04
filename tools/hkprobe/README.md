# hkprobe

Verifies OpenTab's Cmd+Tab takeover mechanism on this machine: after
`CGSSetSymbolicHotKeyEnabled(1, false)`, does a Carbon `RegisterEventHotKey`
receive Cmd+Tab, and does a global `flagsChanged` monitor see the Cmd release?

It is a separate bundle from axprobe on purpose. axprobe promises never to
mutate anything it observes; this tool flips WindowServer hotkey state. Same
stable signing identity, its own bundle id (`im.opentab.tools.hkprobe`), its
own row in the Accessibility list.

## Setup

```sh
make install    # build, sign, copy to ~/Applications
```

Grant Accessibility by hand: System Settings → Privacy & Security →
Accessibility → `+` → Cmd-Shift-G → `~/Applications/HKProbe.app` → toggle on.
Without it the Carbon hotkey part still runs; only the Cmd-release
observation stays silent.

## Commands

| Command | Effect |
|---|---|
| `make status` | Read-only: trust state, symbol resolution, current state of ids 1 and 2 |
| `make run` | The ~30s experiment. A floating panel tells the person at the keyboard what to press in each phase. Two observers log whether the system switcher reacted: Dock-owned windows not present at baseline (the switcher is layer 20, display-sized, drawn only when Cmd is held long enough) and frontmost-app changes |
| `make restore` | Re-enable Cmd+Tab / Cmd+Shift+Tab from a fresh process |

## Safety

The initial state is read with `CopySymbolicHotKeys` before anything changes
and written back on normal exit, SIGINT, SIGTERM, `atexit`, and a 45s
watchdog. The state lives in WindowServer, is not persisted, and any process
can flip it back — `make restore` recovers a run that died before restoring.

## Requirements

Requires Xcode 26 and macOS 26 or later to build; the deployment target is
macOS 14.0. Builds with `swiftc` directly; no Xcode project, no package
dependencies.
