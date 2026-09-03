import XCTest
@testable import OpenTabCore

/// Random operation sequences against a simulated desktop whose reads are
/// truthful (an app's window read lists all its windows or nothing; its tab
/// read lists all its tabs or nothing). Every step checks the store's
/// invariants; every full read of the desktop checks that it converged.
final class TabStorePropertyTests: XCTestCase {
    private struct SplitMix64: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    private struct WorldTab {
        let id: Int
        var title: String
    }

    private struct WorldWindow {
        let id: UInt32
        let app: AppInfo
        var tabs: [WorldTab]
        var active = 0
        var onActiveSpace = true
        var minimized = false
    }

    private struct World {
        static let plain = AppInfo(bundleID: "com.example.plain", pid: 500, localizedName: "Plain")
        static let apps = [chrome, safariApp, plain]

        var windows: [UInt32: WorldWindow] = [:]
        var terminated: Set<AppKey> = []
        var nextWindowID: UInt32 = 1
        var nextTabID = 1
        var nextTitle = 1

        mutating func title() -> String {
            defer { nextTitle += 1 }
            return "Page \(nextTitle)"
        }

        mutating func open(_ app: AppInfo) {
            let id = nextWindowID
            nextWindowID += 1
            let tabs = app == Self.plain ? [] : [WorldTab(id: nextTabID, title: title())]
            nextTabID += 1
            windows[id] = WorldWindow(id: id, app: app, tabs: tabs)
        }

        func windows(of app: AppInfo) -> [WorldWindow] {
            windows.values.filter { $0.app == app }.sorted { $0.id < $1.id }
        }

        var running: [AppInfo] { Self.apps.filter { !terminated.contains($0.key) } }

        static func scriptKey(_ window: WorldWindow) -> WindowKey {
            window.app == chrome ? scripted(chrome, "w\(window.id)") : scripted(safariApp, "\(window.id)")
        }

        func windowSnapshots(of app: AppInfo) -> [WindowSnapshot] {
            windows(of: app).map { window in
                let title: String
                switch app {
                case chrome: title = "\(window.tabs[window.active].title) - Google Chrome"
                case safariApp: title = window.tabs[window.active].title
                default: title = "Plain \(window.id)"
                }
                return WindowSnapshot(key: .cg(window.id), app: app, title: title, subrole: "AXStandardWindow",
                                      isMinimized: window.minimized, isOnActiveSpace: window.onActiveSpace)
            }
        }

        func tabSnapshots(of app: AppInfo) -> [TabSnapshot] {
            windows(of: app).flatMap { window in
                window.tabs.enumerated().map { index, tab in
                    let token = app == chrome ? "t\(tab.id)" : "\(index)"
                    return TabSnapshot(windowKey: Self.scriptKey(window), token: token, title: tab.title,
                                       url: nil, isActive: index == window.active, isPrivate: false)
                }
            }
        }
    }

    private struct Run {
        var rng: SplitMix64
        var world = World()
        var h = StoreHarness()
        var steps = 0

        init(seed: UInt64) {
            rng = SplitMix64(state: seed)
            for app in World.apps { world.open(app) }
        }

        mutating func pick<T>(_ items: [T]) -> T? {
            items.isEmpty ? nil : items[Int.random(in: 0..<items.count, using: &rng)]
        }

        @discardableResult
        mutating func readWindows(_ app: AppInfo) -> ApplyResult {
            h.windows(world.windowSnapshots(of: app), for: app)
        }

        @discardableResult
        mutating func readTabs(_ app: AppInfo) -> ApplyResult {
            h.tabs(world.tabSnapshots(of: app), for: app, stability: app == chrome ? .stable : .positional)
        }

        mutating func readEverything() {
            for app in world.running {
                readWindows(app)
                if app != World.plain { readTabs(app) }
            }
        }

        /// Runs one random operation. Returns whether it may legitimately
        /// change where a row sits: a focus bump, or a claim (the surviving
        /// row takes the claimed window's slot).
        mutating func step() -> Bool {
            steps += 1
            let app = pick(world.running)
            let window = pick(world.windows.values.filter { !world.terminated.contains($0.app.key) })
            switch Int.random(in: 0..<27, using: &rng) {
            case 0:
                if let app { world.open(app) }
            case 1:
                if let window, world.windows(of: window.app).count > 1 { world.windows[window.id] = nil }
            case 2:
                if var window, window.app != World.plain {
                    window.tabs.append(WorldTab(id: world.nextTabID, title: world.title()))
                    world.nextTabID += 1
                    world.windows[window.id] = window
                }
            case 3:
                if var window, window.tabs.count > 1 {
                    window.tabs.remove(at: Int.random(in: 0..<window.tabs.count, using: &rng))
                    window.active = min(window.active, window.tabs.count - 1)
                    world.windows[window.id] = window
                }
            case 4:
                if var window, window.tabs.count > 1 {
                    window.active = Int.random(in: 0..<window.tabs.count, using: &rng)
                    world.windows[window.id] = window
                }
            case 5:
                if var window, !window.tabs.isEmpty {
                    window.tabs[window.active].title = world.title()
                    world.windows[window.id] = window
                }
            case 6:
                if var window, window.tabs.count > 1 {
                    window.tabs.swapAt(0, window.tabs.count - 1)
                    world.windows[window.id] = window
                }
            case 7:
                if var window {
                    window.onActiveSpace.toggle()
                    world.windows[window.id] = window
                }
            case 8:
                if var window {
                    window.minimized.toggle()
                    world.windows[window.id] = window
                }
            case 9, 10, 11:
                if let app { return !readWindows(app).claims.isEmpty }
            case 12, 13:
                if let app, app != World.plain { return !readTabs(app).claims.isEmpty }
            case 14:
                if let app {
                    XCTAssertEqual(h.windows([], for: app).disposition, .rejectedEmpty)
                    XCTAssertEqual(h.tabs([], for: app).disposition, .rejectedEmpty)
                }
            case 15:
                let live = Bool.random(using: &rng) ? Set(world.windows.keys) : nil
                h.sweep(live: live, running: Set(world.running.map(\.key)))
            case 16:
                if let app {
                    let before = h.store.entries
                    let stamp = h.store.beginRead(for: app, kind: .windows)
                    h.store.advanceGeneration(to: h.store.currentGeneration.next())
                    let result = h.store.applyWindows(world.windowSnapshots(of: app), for: app, isHidden: false,
                                                      bumpFocused: true, stamp: stamp, now: h.now)
                    XCTAssertEqual(result.disposition, .staleGeneration)
                    XCTAssertEqual(h.store.entries, before)
                }
            case 17:
                h.store.setPanelVisible(!h.store.isPanelVisible, now: h.now)
                return !h.store.isPanelVisible
            case 18:
                if let entry = pick(h.store.sorted()), !h.store.isPanelVisible {
                    forget(entry)
                    h.store.activationFailed(entry.id)
                }
            case 19:
                if let app, world.running.count > 1 {
                    world.terminated.insert(app.key)
                    for window in world.windows(of: app) { world.windows[window.id] = nil }
                    h.store.removeApp(app.key)
                }
            case 20:
                if let key = pick(Array(world.terminated)), let app = World.apps.first(where: { $0.key == key }) {
                    world.terminated.remove(key)
                    world.open(app)
                }
            case 21:
                if let entry = pick(h.store.sorted()) {
                    h.store.bumpFocus(entry.id)
                    return true
                }
            case 23:
                if let app, app != World.plain {
                    _ = h.store.removeTabs(for: app)
                }
            case 24:
                if let app, let focused = world.windows(of: app).first {
                    let snapshots = world.windowSnapshots(of: app).map { snapshot in
                        WindowSnapshot(key: snapshot.key, app: app, title: snapshot.title, subrole: snapshot.subrole,
                                       isMinimized: snapshot.isMinimized, isOnActiveSpace: snapshot.isOnActiveSpace,
                                       isFocused: snapshot.key == .cg(focused.id))
                    }
                    h.windows(snapshots, for: app, bumpFocused: true)
                    return true
                }
            case 22:
                if let window, window.app == safariApp {
                    let result = h.store.resolve(window: .cg(window.id), toScriptWindow: World.scriptKey(window), now: h.now)
                    return !result.claims.isEmpty
                }
            default:
                h.advance(.milliseconds(Int.random(in: 0...2000, using: &rng)))
            }
            return false
        }

        /// The entry failed to activate: in the world, it is already gone.
        mutating func forget(_ entry: Entry) {
            switch entry.key {
            case .cg(let id):
                if world.windows(of: entry.app).count > 1 { world.windows[id] = nil }
            case .scripted(_, let token):
                let id = entry.app == chrome ? UInt32(token.dropFirst())! : UInt32(token)!
                guard var window = world.windows[id], let tabToken = entry.id.tabToken else { return }
                let index = entry.app == chrome
                    ? window.tabs.firstIndex { "t\($0.id)" == tabToken }
                    : Int(tabToken).flatMap { $0 < window.tabs.count ? $0 : nil }
                guard let index else { return }
                if window.tabs.count == 1 {
                    if world.windows(of: entry.app).count > 1 { world.windows[id] = nil }
                } else {
                    window.tabs.remove(at: index)
                    window.active = min(window.active, window.tabs.count - 1)
                    world.windows[id] = window
                }
            case .ax:
                break
            }
        }

        func checkInvariants(file: StaticString = #filePath, line: UInt = #line) {
            let rows = h.store.sorted()
            XCTAssertEqual(rows.map(\.id), h.store.sorted().map(\.id), "sort is stable", file: file, line: line)
            XCTAssertEqual(Set(rows.map(\.id)).count, rows.count, file: file, line: line)
            // Rows whose removal is deferred linger next to their replacement
            // until the panel closes (H); with it closed there is one row per window.
            if !h.store.isPanelVisible {
                XCTAssertEqual(Set(rows.map(\.key)).count, rows.count, "one row per window", file: file, line: line)
                for row in rows where row.kind == .tab {
                    XCTAssertEqual(h.store.promotedTab(in: row.key)?.id, row.id, file: file, line: line)
                }
            }
            XCTAssertEqual(h.store.flapCount, 0, "step \(steps)", file: file, line: line)
            XCTAssertEqual(h.store.claimConflictCount, 0, "step \(steps)", file: file, line: line)
            for entry in h.store.entries.values {
                XCTAssertGreaterThanOrEqual(entry.missingStrikes, 0, file: file, line: line)
                if !h.store.isPanelVisible {
                    XCTAssertLessThan(entry.missingStrikes, h.store.configuration.missingStrikeThreshold, file: file, line: line)
                }
                if entry.kind == .tab {
                    XCTAssertTrue(h.store.tabs(in: entry.key).contains { $0.id == entry.id }, file: file, line: line)
                }
            }
            XCTAssertTrue(h.store.groupCounts().byWindowKey.values.allSatisfy { $0 >= 1 }, file: file, line: line)
            XCTAssertTrue(h.store.groupCounts().byAppKey.values.allSatisfy { $0 >= 1 }, file: file, line: line)
        }

        /// After a full truthful read with the panel closed, exactly one row
        /// stands for each window: a promoted tab for browser windows, the
        /// window entry for the plain app. Windows that closed while on
        /// another Space are only ever removed by the sweep (F), so the
        /// WindowServer is consulted the full strike count first.
        mutating func checkConverged(file: StaticString = #filePath, line: UInt = #line) {
            h.store.setPanelVisible(false, now: h.now)
            for _ in 0..<h.store.configuration.missingStrikeThreshold {
                h.sweep(live: Set(world.windows.keys), running: Set(world.running.map(\.key)))
            }
            readEverything()
            let expected = Set(world.windows.values.map { window -> WindowKey in
                window.app == World.plain ? .cg(window.id) : World.scriptKey(window)
            })
            XCTAssertEqual(Set(h.store.sorted().map(\.key)), expected, "step \(steps)", file: file, line: line)
            for window in world.windows.values where window.app != World.plain {
                let key = World.scriptKey(window)
                XCTAssertEqual(h.store.tabs(in: key).map(\.title), window.tabs.map(\.title), file: file, line: line)
                XCTAssertEqual(h.store.promotedTab(in: key)?.title, window.tabs[window.active].title, file: file, line: line)
                XCTAssertEqual(h.store.claimedWindow(for: key), .cg(window.id), file: file, line: line)
            }
        }
    }

    func testRandomOperationsKeepTheStoreConsistent() {
        for seed: UInt64 in [1, 2, 3] {
            var run = Run(seed: seed)
            run.readEverything()
            for _ in 0..<1000 {
                let before = run.h.store.sorted().map(\.id)
                let mayReorder = run.step()
                run.checkInvariants()
                if !mayReorder {
                    let after = run.h.store.sorted().map(\.id)
                    let kept = Set(after)
                    XCTAssertEqual(before.filter(kept.contains), after.filter(Set(before).contains),
                                   "rows never swap places without a focus change (seed \(seed), step \(run.steps))")
                }
                if run.steps % 100 == 0 { run.checkConverged() }
            }
            run.checkConverged()
            XCTAssertEqual(run.h.store.flapCount, 0)
        }
    }
}
