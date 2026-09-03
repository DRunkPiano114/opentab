import Foundation
@testable import OpenTabCore

let chrome = AppInfo(bundleID: "com.google.Chrome", pid: 300, localizedName: "Google Chrome")
let safariApp = AppInfo(bundleID: "com.apple.Safari", pid: 400, localizedName: "Safari")

func scripted(_ app: AppInfo, _ token: String) -> WindowKey {
    .scripted(bundleID: app.bundleID, token: token)
}

func tab(_ window: WindowKey, _ token: String, _ title: String, active: Bool = false,
         url: String? = nil, isPrivate: Bool = false) -> TabSnapshot {
    TabSnapshot(windowKey: window, token: token, title: title, url: url.flatMap(URL.init(string:)),
                isActive: active, isPrivate: isPrivate)
}

func chromeWindow(_ id: UInt32, _ page: String, focused: Bool = false, onActiveSpace: Bool = true) -> WindowSnapshot {
    WindowSnapshot(key: .cg(id), app: chrome, title: page.isEmpty ? "" : "\(page) - Google Chrome",
                   subrole: "AXStandardWindow", isMinimized: false, isOnActiveSpace: onActiveSpace,
                   isFocused: focused)
}

/// Drives a `TabStore` with a fixed clock: every read is stamped, and time
/// only moves when a test says so.
struct StoreHarness {
    var store: TabStore
    var now = ContinuousClock.now

    init(configuration: TabStore.Configuration = TabStore.Configuration()) {
        store = TabStore(configuration: configuration)
    }

    @discardableResult
    mutating func windows(_ snapshots: [WindowSnapshot], for app: AppInfo, bumpFocused: Bool = false,
                          isHidden: Bool = false) -> ApplyResult {
        let stamp = store.beginRead(for: app, kind: .windows)
        return store.applyWindows(snapshots, for: app, isHidden: isHidden, bumpFocused: bumpFocused,
                                  stamp: stamp, now: now)
    }

    @discardableResult
    mutating func tabs(_ snapshots: [TabSnapshot], for app: AppInfo,
                       stability: TokenStability = .stable) -> ApplyResult {
        let stamp = store.beginRead(for: app, kind: .tabs)
        return store.applyTabs(snapshots, for: app, stability: stability, stamp: stamp, now: now)
    }

    @discardableResult
    mutating func sweep(live: Set<UInt32>?, running: Set<AppKey>? = nil) -> Bool {
        store.sweep(liveWindowIDs: live, runningApps: running, now: now)
    }

    mutating func advance(_ duration: Duration) {
        now += duration
    }

    var shownKeys: [WindowKey] { store.sorted().map(\.key) }
    var shownIDs: [EntryID] { store.sorted().map(\.id) }
}

/// Chrome titles an incognito window `<page> - Google Chrome (Incognito)`
/// while its window `name` is just `<page>` (measured 2026-09-03).
func incognitoWindow(_ id: UInt32, _ page: String) -> WindowSnapshot {
    WindowSnapshot(key: .cg(id), app: chrome, title: "\(page) - Google Chrome (Incognito)",
                   subrole: "AXStandardWindow", isMinimized: false)
}

/// What a provider hands over for a private window under the default policy:
/// the window, its title, and none of its tabs (L16).
func withheldWindow(_ window: WindowKey, _ title: String) -> TabSnapshot {
    TabSnapshot(windowKey: window, token: "", title: title, url: nil, isActive: true,
                isPrivate: true, withholdsTabs: true)
}
