# axprobe

A read-only Accessibility probe for OpenTab. It captures ground truth about how
real applications expose their windows and tabs to the AX API, so the tab
extraction in OpenTab can be written against observed hierarchies instead of
hypotheses derived from Chromium and Gecko source.

It ships as a signed `.app` bundle for one reason: TCC identity. A bare
executable launched from a terminal that already holds Accessibility inherits
that terminal's grant and reports a false positive. A bundle signed with a
stable identity gets its own row in the Accessibility list.

**This tool never mutates the applications it observes.** It calls only the
`AXUIElementCopy*` family. There is no `AXUIElementPerformAction`, no
`AXUIElementSetAttributeValue`, no raising, closing, or minimizing anywhere in
the source.

## One-time setup

```sh
make install    # builds, signs with a stable identity, copies to ~/Applications
make doctor     # reports "NOT TRUSTED" until permission is granted
```

Then grant permission by hand — this is the one step that cannot be scripted,
because TCC requires human consent by design:

1. Open **System Settings → Privacy & Security → Accessibility**.
2. Click **+**, press **Cmd-Shift-G**, and paste `~/Applications/AXProbe.app`.
3. Select **AXProbe.app**, click **Open**, and switch its toggle **ON**.
4. Run `make doctor` again. It should now report `AXIsProcessTrusted : true`.

No relaunch, logout, or reboot is required: the trust check is a live TCC
lookup. The grant survives rebuilds because the app is signed with a stable
self-signed identity whose designated requirement is

```
identifier "im.opentab.tools.axprobe" and certificate leaf = H"<cert sha1>"
```

An ad-hoc signature would produce a bare `cdhash` requirement instead, which
changes on every non-identical build and silently orphans the grant. If you ever
regenerate the signing certificate or change the bundle id, the grant has to be
given again.

## Commands

| Command | What it answers |
|---|---|
| `make doctor` | Am I trusted? What is my bundle id, designated requirement and cdhash? |
| `make list` | Which apps are running, and how many windows does each expose to AX vs the WindowServer? |
| `make dump APP=<bundle-id\|name>` | What does this app's full AX tree look like? |
| `make tabs APP=<bundle-id\|name>` | Which tab-location strategy works for this app, and where exactly? |
| `make spaces` | Which CGWindowIDs are reachable through AX, and which are not? |
| `make token PID=<pid> WID=<id[,id]>` | Can the remote-token path reach a window AX will not enumerate (other Space, fullscreen)? |
| `make spacemap WID=<id[,id]>` | Which Space is each window on, and which Space is active per display? |
| `make dumps` | Run `dump` and `tabs` across every target app that is currently running. |
| `make selftest` | Do the walker's depth/breadth/budget/deadline caps actually hold? |
| `make reset-perms` | Revoke the grant to retest the first-run experience. |

Every command writes `out/<name>.json` (the complete record, key-sorted so runs
diff cleanly) and `out/<name>.txt` (a readable summary).

### `tabs` strategies

`tabs` runs six independent strategies and reports which ones fired, with the
exact hierarchy path of every hit:

- **S1** `AXTabs` read directly on the application element
- **S2** `AXTabs` read directly on each window element
- **S3** window → depth-1 `AXTabGroup` → `AXSubrole == AXTabButton` children
- **S4** `AXTabs` read on every `AXTabGroup` found anywhere in the scan
- **S5** bounded depth-first search for `AXSubrole == AXTabButton`
- **S6** sweep of every attribute name matching `/tab/i`, anywhere

S1, S2 and S4 exist to settle one question: Chromium implements a recursive
`tabs` accessor, so if it crosses the AX IPC boundary as `AXTabs`, a single read
replaces the whole tree walk. The `verdict` block in the output answers that
directly for each app.

## Running the `spaces` test properly

`spaces` compares AX-reachable windows against the WindowServer's own list. The
result is only meaningful if there is something interesting to find, so set the
machine up first:

1. Open two or three windows on the **current** Space.
2. Create a **second Space** (Mission Control → +) and open windows there.
3. Put one window in **fullscreen** (its own Space).
4. **Minimize** one window on the current Space.
5. Return to the first Space, then run `make spaces`.

Read `cgOnlyCandidateRealWindows` in the output. `CGWindowListCopyWindowInfo`
with `.optionAll` over-reports layer 0 heavily — drop shadows and toolbar strips
appear as windows — so rows smaller than 100pt in either axis are labelled
`smallOrArtifact` and excluded from that count. Every row keeps its label in the
JSON, so the cut can be re-judged without re-running the probe.

## Reaching windows AX will not enumerate (`token`)

`spaces` establishes which windows the plain AX enumeration misses — windows on
another Space, and fullscreen windows (whose owning app reports zero AX windows
at all). `token` tests whether the remote-token path reaches them.

`_AXUIElementRemoteTokenCreate` on a reachable window yields a 20-byte token:

```
0x00  4B  pid
0x04  4B  0
0x08  4B  0x636f636f  "coco"
0x0c  8B  AXUIElementID   (per-window; the first 12 bytes are a process constant)
```

`token` dumps that token for every reachable window, then holds the 12-byte
prefix fixed and sweeps the id at `0x0c`, feeding each candidate to
`_AXUIElementCreateWithRemoteToken`. A candidate is a hit when
`_AXUIElementGetWindow` on it returns the requested CGWindowID **and** its role
is `AXWindow` — the id gate alone matches descendants (tab bar, buttons) too.
When the target app reports no reachable window to seed the prefix from
(fullscreen), the prefix is synthesized as `[pid][0]["coco"]`.

Each invocation targets one pid and flushes per window, so a bad token that
segfaults costs one data point, not the batch. The sweep is bounded by
`--budget` (wall clock, default 8s) and `--max-id` (default 32768).

`spacemap` answers Space attribution with no AX call:
`CGSCopyManagedDisplaySpaces` gives the current Space of each display and
`CGSCopySpacesForWindows` (mask `0x7`) gives the Space of each window, so
"is this window on its display's active Space" is a set-membership test.
`SLSWindowIsOnCurrentSpace` is unreliable here (it returns false even for
current-Space windows); use the CGS set instead.

## Bounding, and why it is there

A probe must never hang on a hostile or wedged application. Four independent
limits apply, and every one of them records a marker in the output rather than
failing silently, so a partial dump is always distinguishable from a complete
one:

| Limit | Default | Flag |
|---|---|---|
| Tree depth | 12 (hard ceiling 64) | `--max-depth` |
| Total nodes | 4000 | `--max-nodes` |
| Children per node | 100 | `--max-children` |
| Wall clock per walk | 20s | `--budget` |
| Per-read AX messaging timeout | 0.25s | `--timeout` |

The messaging timeout is set once on the **system-wide** element. Setting it on
an application element does not propagate to that application's windows, which
is where the time is actually spent.

Ancestor cycles are detected and marked too. `make selftest` verifies all of
this against synthetic trees of unbounded depth and breadth, with slow nodes and
a deliberate parent cycle. It needs no permission and touches no other process.

## Rules this tool follows

- **Always launch through `open -n -W -a`.** Every Makefile target does. Running
  `build/AXProbe.app/Contents/MacOS/axprobe` from a granted terminal reports
  `AXIsProcessTrusted : true` for the same binary that reports `false` when
  launched properly. `doctor` warns when its parent process looks like a shell.
- **Never probe `getpid()`.** A same-process AX call is not IPC; it dispatches
  inline into AppKit, which is main-thread-only. `Targets.running()` excludes
  self unconditionally.
- **Never write `AXEnhancedUserInterface` or `AXManualAccessibility`.** The
  first belongs to VoiceOver and clobbering it breaks window management
  system-wide; neither is needed to enumerate windows or tabs.

## Privacy note

AX dumps contain window titles, document names, and the value of text elements —
open URLs, file paths, and message text among them. String attribute values are
truncated to 200 characters (`--max-string`), but the dumps are still a snapshot
of whatever was on screen. Read `out/` before committing anything from it.

## Troubleshooting

**The toggle is ON but `doctor` still reports `false`.** The stored code
requirement is stale. Toggling off and on does not fix it — that flips the
authorization on the same row with the same stale requirement. Remove the row
with the **−** button and add it again, or run `make reset-perms` and re-grant.

**`tccutil` says "No such bundle identifier".** `tccutil` resolves bundle ids
through LaunchServices, which will not resolve an app under `build/` or `/tmp`.
Run `make install` first so the app lives in `~/Applications`.

**A dump is truncated.** Check `walk.truncations` in the JSON for the reason and
raise the corresponding limit. `budget` truncation on a specific app usually
means that app is slow to answer AX, not that the tree is large.

## Layout

```
Makefile                     build / sign / install / probe targets
Scripts/make-signing-cert.sh creates the stable self-signed identity
Support/Info.plist           bundle identity (LSUIElement, non-sandboxed)
Sources/
  AXProbe.swift              entry point and command dispatch
  CLI.swift                  argument parsing and usage
  AX.swift                   AX read helpers, error names, value rendering
  AXTreeSource.swift         the accessibility hierarchy as a TreeSource
  TreeWalker.swift           bounded walker, shared by real and synthetic trees
  SyntheticTreeSource.swift  hostile tree shapes for the self-test
  Command*.swift             one file per command
  JSON.swift, Output.swift   deterministic JSON and file output
out/                         command results (JSON + text summaries)
```

Requires Xcode 26 and macOS 26 or later to build; the deployment target is
macOS 14.0. Builds with `swiftc` directly; no Xcode project, no package
dependencies.
