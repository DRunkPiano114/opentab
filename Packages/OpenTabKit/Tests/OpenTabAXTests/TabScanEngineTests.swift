import CoreGraphics
import OpenTabCore
import XCTest
@testable import OpenTabAX

/// A forest of windows. A window node's id is its CGWindowID times 1 000;
/// its tab buttons follow it. Every title is invented.
private struct Windows: TabTreeSource {
    typealias Node = Int

    struct Window {
        var tabs: [String]
        var active: Int?
        /// The window node does not answer, like a remote element that went stale.
        var unreadable = false
        var role = "AXWindow"
    }

    var windows: [CGWindowID: Window]

    static func node(_ id: CGWindowID) -> Int { Int(id) * 1_000 }

    func attributes(of node: Int) -> TabNodeAttributes? {
        let (wid, offset) = (CGWindowID(node / 1_000), node % 1_000)
        guard let window = windows[wid], !window.unreadable else { return nil }
        if offset == 0 {
            return TabNodeAttributes(role: window.role, subrole: "AXStandardWindow", title: "", description: "",
                                     isSelected: false)
        }
        let index = offset - 1
        guard window.tabs.indices.contains(index) else { return nil }
        return TabNodeAttributes(role: "AXRadioButton", subrole: "AXTabButton", title: window.tabs[index],
                                 description: "", isSelected: index == window.active)
    }

    func children(of node: Int, limit: Int) -> [Int] {
        guard node % 1_000 == 0, let window = windows[CGWindowID(node / 1_000)] else { return [] }
        return window.tabs.indices.map { node + $0 + 1 }.prefix(limit).map { $0 }
    }
}

final class TabScanEngineTests: XCTestCase {
    private let far = ContinuousClock.now + .seconds(3_600)

    private func engine(_ windows: [CGWindowID: Windows.Window], layers: [CGWindowID: Int32]? = nil)
        -> TabScanEngine<Windows> {
        let layers = layers ?? windows.mapValues { _ in 0 }
        let source = Windows(windows: windows)
        return TabScanEngine(source: source,
                             // Read apart from the walk: a window can pass this
                             // filter and stop answering before its tree is read.
                             isListable: { windows[CGWindowID($0 / 1_000)]?.role == "AXWindow" },
                             windowID: { CGWindowID($0 / 1_000) },
                             layer: { layers[$0] })
    }

    private func node(_ id: CGWindowID) -> Int { Windows.node(id) }

    // MARK: Windows Accessibility lists

    func testSnapshotsAreKeyedByWindowNumberWithPositionalTokensAndOneActiveTab() throws {
        let engine = engine([91: .init(tabs: ["alpha", "beta", "gamma"], active: 1)])
        let scan = try engine.scan(.init(axWindows: [node(91)]), deadline: far)
        XCTAssertEqual(scan.snapshots.map(\.windowKey), [.cg(91), .cg(91), .cg(91)])
        XCTAssertEqual(scan.snapshots.map(\.token), ["0", "1", "2"])
        XCTAssertEqual(scan.snapshots.map(\.title), ["alpha", "beta", "gamma"])
        XCTAssertEqual(scan.snapshots.filter(\.isActive).map(\.token), ["1"])
        XCTAssertEqual(scan.tabs[91]?.count, 3)
    }

    func testNoWindowAtAllIsNoEvidence() {
        XCTAssertThrowsError(try engine([:]).scan(.init(axWindows: []), deadline: far)) {
            XCTAssertEqual($0 as? AXSourceError, .cannotComplete)
        }
    }

    func testUnreadableWindowAloneIsNoEvidence() {
        let engine = engine([91: .init(tabs: ["alpha"], active: 0, unreadable: true)])
        XCTAssertThrowsError(try engine.scan(.init(axWindows: [node(91)]), deadline: far)) {
            XCTAssertEqual($0 as? AXSourceError, .cannotComplete)
        }
    }

    /// A complete scan that finds no tab strip is a real answer: the app has
    /// no tabs right now.
    func testCompleteScanWithoutTabsReportsNone() throws {
        let scan = try engine([91: .init(tabs: [], active: nil)]).scan(.init(axWindows: [node(91)]), deadline: far)
        XCTAssertTrue(scan.snapshots.isEmpty)
        XCTAssertEqual(scan.windowsScanned, 1)
    }

    func testWindowsOffLayerZeroOrNotListableAreSkipped() throws {
        let engine = engine([91: .init(tabs: ["alpha"], active: 0),
                             92: .init(tabs: ["beta"], active: 0),
                             93: .init(tabs: ["gamma"], active: 0, role: "AXSheet")],
                            layers: [91: 0, 92: 3, 93: 0])
        let scan = try engine.scan(.init(axWindows: [node(91), node(92), node(93)]), deadline: far)
        XCTAssertEqual(Set(scan.snapshots.map(\.windowKey)), [.cg(91)])
        XCTAssertEqual(scan.windowsScanned, 1)
    }

    // MARK: Windows only the off-Space source lists

    func testWindowInBothListsIsReadOnce() throws {
        let engine = engine([91: .init(tabs: ["alpha", "beta"], active: 0)])
        let scan = try engine.scan(.init(axWindows: [node(91)], offSpace: [(91, node(91))]), deadline: far)
        XCTAssertEqual(scan.snapshots.map(\.token), ["0", "1"])
        XCTAssertEqual(scan.windowsScanned, 1)
        XCTAssertEqual(scan.windowsOffSpace, 0)
    }

    /// A full-screen group: Accessibility lists no window at all, the
    /// off-Space source reached one.
    func testOffSpaceWindowIsScannedWhenAccessibilityListsNone() throws {
        let engine = engine([82: .init(tabs: ["one", "two", "three"], active: 2)])
        let scan = try engine.scan(.init(axWindows: [], offSpace: [(82, node(82))]), deadline: far)
        XCTAssertEqual(scan.snapshots.map(\.windowKey), [.cg(82), .cg(82), .cg(82)])
        XCTAssertEqual(scan.snapshots.map(\.token), ["0", "1", "2"])
        XCTAssertEqual(scan.snapshots.map(\.title), ["one", "two", "three"])
        XCTAssertEqual(scan.snapshots.filter(\.isActive).map(\.token), ["2"])
        XCTAssertEqual(scan.tabs[82]?.count, 3)
        XCTAssertEqual(scan.windowsScanned, 1)
        XCTAssertEqual(scan.windowsOffSpace, 1)
        XCTAssertEqual(scan.emitted[82], scan.snapshots)
    }

    func testOffSpaceWindowAlongsideAccessibilityWindows() throws {
        let engine = engine([91: .init(tabs: ["alpha"], active: 0), 82: .init(tabs: ["one", "two"], active: 0)])
        let scan = try engine.scan(.init(axWindows: [node(91)], offSpace: [(82, node(82))]), deadline: far)
        XCTAssertEqual(scan.snapshots.map(\.windowKey), [.cg(91), .cg(82), .cg(82)])
        XCTAssertEqual(scan.snapshots.filter(\.isActive).map(\.windowKey), [.cg(91), .cg(82)])
    }

    func testOffSpaceWindowOffLayerZeroIsSkipped() throws {
        let engine = engine([91: .init(tabs: ["alpha"], active: 0), 82: .init(tabs: ["one"], active: 0)],
                            layers: [91: 0, 82: 3])
        let scan = try engine.scan(.init(axWindows: [node(91)], offSpace: [(82, node(82))]), deadline: far)
        XCTAssertEqual(Set(scan.snapshots.map(\.windowKey)), [.cg(91)])
        XCTAssertEqual(scan.windowsOffSpace, 0)
    }

    /// The token element is the only route to an off-Space window, and one
    /// that stopped answering says nothing about its tabs.
    func testUnreadableOffSpaceWindowAloneIsNoEvidence() {
        let engine = engine([82: .init(tabs: ["one"], active: 0, unreadable: true)])
        XCTAssertThrowsError(try engine.scan(.init(axWindows: [], offSpace: [(82, node(82))]), deadline: far)) {
            XCTAssertEqual($0 as? AXSourceError, .cannotComplete)
        }
    }

    /// The user leaves the Space: the window read through Accessibility a
    /// moment ago is now listed by the off-Space source, which has not
    /// reached it. Its tabs stand in, so the group keeps its rows.
    func testUnreachedWindowRepeatsItsLastTabs() throws {
        let engine = engine([91: .init(tabs: [], active: nil), 82: .init(tabs: ["one", "two", "three"], active: 1)])
        let before = try engine.scan(.init(axWindows: [node(91), node(82)]), deadline: far)
        XCTAssertEqual(before.snapshots.count, 3)

        let after = try engine.scan(.init(axWindows: [node(91)], offSpace: [(82, nil)], cached: before.emitted),
                                    deadline: far)
        XCTAssertEqual(after.snapshots, before.snapshots)
        XCTAssertEqual(after.reused, [82])
        XCTAssertNil(after.tabs[82], "nothing was read; the earlier nodes stand")
        XCTAssertEqual(after.emitted[82], before.snapshots, "the tabs keep standing in on the next round")
        XCTAssertEqual(after.windowsOffSpace, 0)
    }

    func testUnreachedWindowWithNoEarlierTabsAddsNothing() throws {
        let engine = engine([91: .init(tabs: ["alpha"], active: 0)])
        let scan = try engine.scan(.init(axWindows: [node(91)], offSpace: [(82, nil)]), deadline: far)
        XCTAssertEqual(Set(scan.snapshots.map(\.windowKey)), [.cg(91)])
        XCTAssertTrue(scan.reused.isEmpty)
    }

    /// A window neither list names any more is gone; what it showed is not
    /// carried forward.
    func testWindowNoLongerListedIsNotCarriedForward() throws {
        let engine = engine([91: .init(tabs: ["alpha"], active: 0)])
        let stale = [TabSnapshot(windowKey: .cg(82), token: "0", title: "one", url: nil, isActive: true,
                                 isPrivate: false)]
        let scan = try engine.scan(.init(axWindows: [node(91)], cached: [82: stale]), deadline: far)
        XCTAssertEqual(Set(scan.snapshots.map(\.windowKey)), [.cg(91)])
        XCTAssertNil(scan.emitted[82])
    }

    // MARK: Through the store

    private let finder = AppInfo(bundleID: "com.apple.finder", pid: 500, localizedName: "Finder")
    private var group: WindowKey { .scripted(bundleID: finder.bundleID, token: "82") }

    private func window(_ id: CGWindowID, onActiveSpace: Bool) -> WindowSnapshot {
        WindowSnapshot(key: .cg(id), app: finder, title: "window \(id)", subrole: "AXStandardWindow",
                       isMinimized: false, isOnActiveSpace: onActiveSpace, level: 0)
    }

    private func applyWindows(_ snapshots: [WindowSnapshot], to store: inout TabStore) {
        let stamp = store.beginRead(for: finder, kind: .windows)
        _ = store.applyWindows(snapshots, for: finder, isHidden: false, stamp: stamp)
    }

    /// What the coordinator does with an Accessibility read: a `.cg` window
    /// becomes the scripted form the store keys tabs by, the window number is
    /// recorded as the claim, and a read with no tab at all drops the app's
    /// tab rows.
    private func applyTabs(_ scan: TabScanEngine<Windows>.Scan, to store: inout TabStore) {
        guard !scan.snapshots.isEmpty else {
            _ = store.removeTabs(for: finder)
            return
        }
        let rekeyed = scan.snapshots.map { snapshot -> TabSnapshot in
            guard case .cg(let wid) = snapshot.windowKey else { return snapshot }
            let key = WindowKey.scripted(bundleID: finder.bundleID, token: String(wid))
            _ = store.resolve(window: .cg(wid), toScriptWindow: key)
            return TabSnapshot(windowKey: key, token: snapshot.token, title: snapshot.title, url: snapshot.url,
                               isActive: snapshot.isActive, isPrivate: snapshot.isPrivate)
        }
        let stamp = store.beginRead(for: finder, kind: .tabs)
        _ = store.applyTabs(rekeyed, for: finder, stability: .positional, stamp: stamp)
    }

    private func assertOneOffSpaceGroupRow(_ store: TabStore, file: StaticString = #filePath, line: UInt = #line) {
        let shown = store.sorted()
        XCTAssertEqual(Set(shown.map(\.key)), [.cg(91), group], file: file, line: line)
        let row = shown.first { $0.key == group }
        XCTAssertEqual(row?.title, "two", "the active tab stands for the group", file: file, line: line)
        XCTAssertEqual(row?.isOnActiveSpace, false, file: file, line: line)
        XCTAssertEqual(store.groupCounts().byWindowKey[group], 3, file: file, line: line)
        XCTAssertEqual(store.tabs(in: group).map(\.title), ["one", "two", "three"], file: file, line: line)
        XCTAssertEqual(store.claimedWindow(for: group), .cg(82), "raised before a tab is pressed",
                       file: file, line: line)
    }

    /// Finder with one plain window here (91, a single tab, so no tab strip)
    /// and a three-tab window on another Space (82).
    func testOffSpaceGroupIsOneRowThatListsItsTabs() throws {
        let engine = engine([91: .init(tabs: [], active: nil), 82: .init(tabs: ["one", "two", "three"], active: 1)])
        var store = TabStore()
        applyWindows([window(91, onActiveSpace: true), window(82, onActiveSpace: false)], to: &store)
        let scan = try engine.scan(.init(axWindows: [node(91)], offSpace: [(82, node(82))]), deadline: far)
        applyTabs(scan, to: &store)
        assertOneOffSpaceGroupRow(store)

        // The next round: AX lists only 91 and the token element of 82 did not
        // answer the source's check, so 82 comes without an element.
        applyWindows([window(91, onActiveSpace: true)], to: &store)
        let unreached = try engine.scan(.init(axWindows: [node(91)], offSpace: [(82, nil)], cached: scan.emitted),
                                        deadline: far)
        applyTabs(unreached, to: &store)
        assertOneOffSpaceGroupRow(store)
    }
}
