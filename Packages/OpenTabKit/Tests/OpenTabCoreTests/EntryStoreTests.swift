import XCTest
@testable import OpenTabCore

final class EntryStoreTests: XCTestCase {
    let safari = app("Safari", pid: 100)
    let xcode = app("Xcode", pid: 200)

    func testOrderIsStableAcrossRepeatedSorts() {
        var store = EntryStore()
        let windows = (1...50).map { window(UInt32($0), safari) }
        store.applyWindows(windows, for: safari, isHidden: false)
        let first = store.sorted().map(\.id)
        for _ in 0..<20 {
            XCTAssertEqual(store.sorted().map(\.id), first)
        }
        XCTAssertEqual(first, windows.map { EntryID.window($0.key) }, "insertion order is the tie-break")
    }

    func testTwoStoresFedTheSameInputAgree() {
        var a = EntryStore(), b = EntryStore()
        let windows = (1...30).map { window(UInt32($0), safari) }
        a.applyWindows(windows, for: safari, isHidden: false)
        b.applyWindows(windows, for: safari, isHidden: false)
        XCTAssertEqual(a.sorted().map(\.id), b.sorted().map(\.id))
    }

    func testDiscoveryRankIsNeverReassigned() {
        var store = EntryStore()
        store.applyWindows([window(1, safari), window(2, safari)], for: safari, isHidden: false)
        let rank2 = store.entries[.window(.cg(2))]!.discoveryRank
        store.applyWindows([window(2, safari), window(3, safari), window(1, safari)], for: safari, isHidden: false)
        XCTAssertEqual(store.entries[.window(.cg(2))]!.discoveryRank, rank2)
        XCTAssertGreaterThan(store.entries[.window(.cg(3))]!.discoveryRank, rank2)
    }

    func testFocusBumpMovesEntryToTop() {
        var store = EntryStore()
        store.applyWindows([window(1, safari), window(2, safari)], for: safari, isHidden: false)
        store.applyWindows([window(3, xcode)], for: xcode, isHidden: false)
        store.bumpFocus(.window(.cg(2)))
        store.bumpFocus(.window(.cg(3)))
        XCTAssertEqual(store.sorted().map(\.key), [.cg(3), .cg(2), .cg(1)])
    }

    func testApplyWithBumpFocusedUsesTheFocusedWindow() {
        var store = EntryStore()
        store.applyWindows([window(1, safari), window(2, safari, focused: true)], for: safari,
                           isHidden: false, bumpFocused: true)
        XCTAssertEqual(store.sorted().first?.key, .cg(2))
    }

    func testEmptyReadNeverDeletes() {
        var store = EntryStore()
        store.applyWindows([window(1, safari)], for: safari, isHidden: false)
        XCTAssertFalse(store.applyWindows([], for: safari, isHidden: false))
        XCTAssertEqual(store.entries.count, 1)
    }

    func testNonEmptyReadDropsMissingWindowsOfThatAppOnly() {
        var store = EntryStore()
        store.applyWindows([window(1, safari), window(2, safari)], for: safari, isHidden: false)
        store.applyWindows([window(3, xcode)], for: xcode, isHidden: false)
        store.applyWindows([window(2, safari)], for: safari, isHidden: false)
        XCTAssertEqual(Set(store.entries.keys), [.window(.cg(2)), .window(.cg(3))])
    }

    func testRemoveApp() {
        var store = EntryStore()
        store.applyWindows([window(1, safari)], for: safari, isHidden: false)
        store.applyWindows([window(3, xcode)], for: xcode, isHidden: false)
        XCTAssertTrue(store.removeApp(safari.key))
        XCTAssertEqual(store.entries.count, 1)
        XCTAssertFalse(store.removeApp(safari.key))
    }

    func testMinimizedStateComesFromSnapshot() {
        var store = EntryStore()
        store.applyWindows([window(1, safari, minimized: true)], for: safari, isHidden: false)
        XCTAssertTrue(store.entries[.window(.cg(1))]!.isMinimized)
        store.applyWindows([window(1, safari, minimized: false)], for: safari, isHidden: false)
        XCTAssertFalse(store.entries[.window(.cg(1))]!.isMinimized)
    }

    func testHiddenFlagFollowsSetHidden() {
        var store = EntryStore()
        store.applyWindows([window(1, safari)], for: safari, isHidden: false)
        XCTAssertTrue(store.setHidden(true, for: safari.key))
        XCTAssertTrue(store.entries[.window(.cg(1))]!.isHidden)
        XCTAssertFalse(store.setHidden(true, for: safari.key))
    }

    func testGroupCountsOmitSingletons() {
        var store = EntryStore()
        store.applyWindows([window(1, safari), window(2, safari)], for: safari, isHidden: false)
        store.applyWindows([window(3, xcode)], for: xcode, isHidden: false)
        let counts = store.groupCounts()
        XCTAssertEqual(counts.displayCount(forApp: safari.key), 2)
        XCTAssertNil(counts.displayCount(forApp: xcode.key))
    }

    func testAlphabeticalSort() {
        var store = EntryStore()
        store.applyWindows([window(3, xcode, title: "b"), window(4, xcode, title: "a")], for: xcode, isHidden: false)
        store.applyWindows([window(1, safari, title: "z")], for: safari, isHidden: false)
        XCTAssertEqual(store.sorted(mode: .alphabetical).map(\.key), [.cg(1), .cg(4), .cg(3)])
    }

    func testDefaultIgnoreListDropsSystemUI() {
        var store = EntryStore()
        let dock = AppInfo(bundleID: "com.apple.dock", pid: 5, localizedName: "Dock")
        store.applyWindows([window(9, dock)], for: dock, isHidden: false)
        XCTAssertTrue(store.isEmpty)
    }

    func testUserTitlePatternIgnoresMatchingWindows() {
        var store = EntryStore(ignoreRules: IgnoreRules(titlePatterns: ["^Picture in Picture$"]))
        store.applyWindows([window(1, safari, title: "Picture in Picture"), window(2, safari, title: "Docs")],
                           for: safari, isHidden: false)
        XCTAssertEqual(store.sorted().map(\.key), [.cg(2)])
    }
}
