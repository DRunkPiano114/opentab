import Foundation
import OpenTabAX
import OpenTabCore
import OpenTabScript
import XCTest
import os
@testable import OpenTab

/// The store, the providers and the window source wired together the way
/// the app wires them, driven with fake snapshots. Every scenario here is
/// one the packet lists as an integration failure that no library test can
/// see.
@MainActor
final class CoordinatorTests: XCTestCase {
    private var harness: CoordinatorHarness!
    private var provider: FakeTabProvider!

    override func setUp() async throws {
        provider = FakeTabProvider(bundleIDs: [chrome.bundleID])
        harness = CoordinatorHarness(providers: [provider], live: [1, 2, 3])
        harness.directory.set(apps: [chrome, notes])
        harness.directory.setFrontmost(chrome)
        harness.source.set([chromeWindow(1, "GitHub", focused: true), chromeWindow(2, "Docs"), chromeWindow(3, "Mail")], for: chrome)
        harness.source.set([window(9, notes, title: "Groceries")], for: notes)
        provider.set(tabs: [
            chromeTab("w1", "t1", "GitHub", active: true), chromeTab("w1", "t2", "Pull requests"), chromeTab("w1", "t3", "Issues"),
            chromeTab("w2", "t4", "Docs", active: true), chromeTab("w2", "t5", "Sheets"),
            chromeTab("w3", "t6", "Mail", active: true),
        ])
    }

    private func activateChrome() async {
        await harness.coordinator.handle(.appActivated(chrome, FocusGeneration(raw: 1)))
    }

    private var chromeRows: [PanelViewModel.Row] {
        harness.rows.filter { $0.appName == chrome.localizedName }
    }

    // MARK: Three Chrome windows (packet §3, the reason this packet exists)

    func testThreeChromeWindowsGiveExactlyThreeRowsWithTabCounts() async {
        await activateChrome()

        let rows = chromeRows
        XCTAssertEqual(rows.count, 3, "\(rows.map(\.title))")
        XCTAssertEqual(harness.entries.filter { $0.app.key == chrome.key }.map(\.kind), [.tab, .tab, .tab])
        XCTAssertEqual(rows.map(\.title), ["GitHub", "Docs", "Mail"])
        XCTAssertEqual(rows.map(\.count), [3, 2, nil])
        XCTAssertEqual(rows.map(\.status), [.normal, .normal, .normal])
        XCTAssertEqual(harness.coordinator.store.flapCount, 0)
        XCTAssertEqual(harness.coordinator.store.claimConflictCount, 0)
        XCTAssertEqual(harness.rows.first?.title, "GitHub", "the focused window leads the list")
    }

    func testRepeatedReadsKeepThreeRows() async {
        await activateChrome()
        for _ in 0..<3 {
            await harness.coordinator.handle(.periodic)
            await harness.coordinator.handle(.titleChanged(chrome))
        }
        XCTAssertEqual(chromeRows.count, 3)
        XCTAssertEqual(harness.coordinator.store.flapCount, 0)
    }

    func testClosedTabLeavesTheListAfterTheNextRead() async {
        await activateChrome()
        XCTAssertEqual(harness.coordinator.store.tabs(in: .scripted(bundleID: chrome.bundleID, token: "w1")).count, 3)

        provider.set(tabs: [
            chromeTab("w1", "t1", "GitHub", active: true), chromeTab("w1", "t3", "Issues"),
            chromeTab("w2", "t4", "Docs", active: true), chromeTab("w2", "t5", "Sheets"),
            chromeTab("w3", "t6", "Mail", active: true),
        ])
        await harness.coordinator.handle(.periodic)

        let w1 = WindowKey.scripted(bundleID: chrome.bundleID, token: "w1")
        XCTAssertEqual(harness.coordinator.store.tabs(in: w1).map(\.id.tabToken), ["t1", "t3"])
        XCTAssertEqual(chromeRows.first { $0.title == "GitHub" }?.count, 2)
    }

    func testClosedWindowLeavesTheListAfterTheNextRead() async {
        await activateChrome()
        harness.source.set([chromeWindow(1, "GitHub", focused: true), chromeWindow(2, "Docs")], for: chrome)
        provider.set(tabs: [
            chromeTab("w1", "t1", "GitHub", active: true),
            chromeTab("w2", "t4", "Docs", active: true),
        ])
        await harness.coordinator.handle(.periodic)
        XCTAssertEqual(chromeRows.map(\.title), ["GitHub", "Docs"])
    }

    // MARK: Failure modes (packet §4)

    func testAutomationRefusalDegradesTheBrowserToWindowsOnly() async {
        await activateChrome()
        provider.failReads(with: .notPermitted)
        await harness.coordinator.handle(.periodic)

        let rows = chromeRows
        XCTAssertEqual(rows.count, 3)
        XCTAssertEqual(harness.entries.filter { $0.app.key == chrome.key }.map(\.kind), [.window, .window, .window])
        XCTAssertEqual(rows.map(\.status), [.tabsUnavailable, .tabsUnavailable, .tabsUnavailable])
        XCTAssertEqual(rows.map(\.count), [3, 3, 3], "window rows count the app's windows again")
        XCTAssertEqual(harness.gate.deniedBundleIDs, [chrome.bundleID])

        let reads = provider.reads
        await harness.coordinator.handle(.periodic)
        await activateChrome()
        XCTAssertEqual(provider.reads, reads, "a refused browser is not asked again")
        XCTAssertEqual(harness.coordinator.store.flapCount, 0)
    }

    func testTabReadTimeoutKeepsTheCachedRows() async {
        await activateChrome()
        provider.failReads(with: .timedOut)
        await harness.coordinator.handle(.periodic)
        XCTAssertEqual(chromeRows.map(\.title), ["GitHub", "Docs", "Mail"])
        XCTAssertEqual(chromeRows.map(\.count), [3, 2, nil])
        XCTAssertEqual(chromeRows.map(\.status), [.normal, .normal, .normal])
    }

    func testWindowReadTimeoutMarksTheAppAndKeepsItsRows() async {
        await activateChrome()
        harness.source.fail(chrome, with: .deadlineExceeded)
        await harness.coordinator.handle(.periodic)
        XCTAssertEqual(chromeRows.map(\.title), ["GitHub", "Docs", "Mail"])
        XCTAssertEqual(chromeRows.map(\.status), [.unresponsive, .unresponsive, .unresponsive])
        XCTAssertEqual(harness.rows.first { $0.appName == notes.localizedName }?.status, .normal,
                       "one wedged app does not mark the others")

        harness.source.fail(chrome, with: nil)
        await harness.coordinator.handle(.periodic)
        XCTAssertEqual(chromeRows.map(\.status), [.normal, .normal, .normal])
    }

    func testTargetGoneMidReadRemovesTheApp() async {
        await activateChrome()
        provider.failReads(with: .targetNotRunning)
        await harness.coordinator.handle(.titleChanged(chrome))
        XCTAssertTrue(chromeRows.isEmpty)
    }

    func testUnscriptableForkFallsBackToWindows() async {
        await activateChrome()
        provider.failReads(with: .compileFailed(code: -2741, message: ""))
        await harness.coordinator.handle(.periodic)
        XCTAssertEqual(harness.entries.filter { $0.app.key == chrome.key }.map(\.kind), [.window, .window, .window])
        XCTAssertTrue(harness.providers.unsupported.contains(chrome.bundleID))
    }

    // MARK: Activation (rule I and the landing check)

    private func tabEntry(_ title: String) -> Entry {
        harness.entries.first { $0.kind == .tab && $0.title == title }!
    }

    func testActivatingATabRaisesItsWindowThenSelectsIt() async {
        await activateChrome()
        provider.onActivate { tab, tabs in
            tabs = tabs.map { TabSnapshot(windowKey: $0.windowKey, token: $0.token, title: $0.title, url: $0.url,
                                          isActive: $0.token == tab.token, isPrivate: $0.isPrivate) }
        }
        let entry = tabEntry("Docs")
        await harness.coordinator.activate(entry)
        XCTAssertEqual(harness.activator.activated, [.cg(2)], "the claimed window is raised first")
        XCTAssertEqual(provider.activated.map(\.token), ["t4"])
        XCTAssertNotNil(harness.entries.first { $0.id == entry.id })
    }

    func testTabReportedGoneIsRemovedWithoutStrikes() async {
        await activateChrome()
        provider.failActivation(with: .notFound)
        provider.failReads(with: .timedOut)
        let entry = tabEntry("Docs")
        await harness.coordinator.activate(entry)
        XCTAssertNil(harness.entries.first { $0.id == entry.id })
        XCTAssertEqual(provider.activated.count, 1, "nothing to retry with")
        XCTAssertEqual(chromeRows.count, 3, "the window keeps a row through its remaining tab")
    }

    /// Safari selects by index. The read taken after the selection shows
    /// that a different tab became active; the tab with the expected title
    /// is now at another index, and that one is selected on the retry.
    func testPositionalMissRetriesOnceWithTheTabThatMoved() async {
        let safariProvider = FakeTabProvider(bundleIDs: [safari.bundleID], tokenStability: .positional)
        harness = CoordinatorHarness(providers: [safariProvider], live: [7])
        harness.directory.set(apps: [safari])
        harness.source.set([window(7, safari, title: "Apple", focused: true)], for: safari)
        safariProvider.set(tabs: [safariTab(7, 1, "Apple", active: true), safariTab(7, 2, "Swift Forums"), safariTab(7, 3, "WWDC")])
        await harness.coordinator.handle(.appActivated(safari, FocusGeneration(raw: 1)))
        XCTAssertEqual(harness.rows.map(\.count), [3])

        // Tab 2 was closed before the user committed: Safari's tab 3 is now
        // "WWDC" at index 2, and selecting index 2 lands on it.
        safariProvider.set(tabs: [safariTab(7, 1, "Apple"), safariTab(7, 2, "WWDC", active: true), safariTab(7, 3, "Swift Forums")])
        safariProvider.onActivate { tab, tabs in
            tabs = tabs.map { TabSnapshot(windowKey: $0.windowKey, token: $0.token, title: $0.title, url: $0.url,
                                          isActive: $0.token == tab.token, isPrivate: $0.isPrivate) }
        }
        let entry = harness.entries.first!
        XCTAssertEqual(entry.kind, .tab)
        let forums = harness.coordinator.store.tabs(in: entry.key).first { $0.title == "Swift Forums" }!
        await harness.coordinator.activate(forums)

        XCTAssertEqual(safariProvider.activated.map(\.token), ["2", "3"], "index 2 missed; the retry addresses index 3")
        XCTAssertEqual(safariProvider.activated.map(\.title), ["Swift Forums", "Swift Forums"])
        let tabs = harness.coordinator.store.tabs(in: entry.key)
        XCTAssertEqual(tabs.map(\.title), ["Apple", "WWDC", "Swift Forums"], "the read taken for the landing check is kept")
    }

    func testSafariWindowsAreClaimedByResolutionNotTitle() async {
        let safariProvider = FakeTabProvider(bundleIDs: [safari.bundleID], tokenStability: .positional)
        harness = CoordinatorHarness(providers: [safariProvider], live: [7, 8])
        harness.directory.set(apps: [safari])
        harness.source.set([window(7, safari, title: "Untitled"), window(8, safari, title: "Untitled", focused: true)], for: safari)
        safariProvider.set(tabs: [safariTab(7, 1, "Apple", active: true), safariTab(8, 1, "Swift Forums", active: true)])
        await harness.coordinator.handle(.appActivated(safari, FocusGeneration(raw: 1)))

        let entries = harness.entries
        XCTAssertEqual(entries.map(\.kind), [.tab, .tab])
        XCTAssertEqual(Set(entries.map(\.key)), [.scripted(bundleID: safari.bundleID, token: "7"),
                                                .scripted(bundleID: safari.bundleID, token: "8")])
        XCTAssertEqual(harness.coordinator.store.claimedWindow(for: .scripted(bundleID: safari.bundleID, token: "7")), .cg(7))
        XCTAssertEqual(harness.coordinator.store.claimedWindow(for: .scripted(bundleID: safari.bundleID, token: "8")), .cg(8))
        XCTAssertEqual(entries.first?.title, "Swift Forums", "the focused window's tab leads")
        XCTAssertEqual(harness.coordinator.store.claimConflictCount, 0)
    }

    func testWindowWithoutAnElementFallsBackToTheAppAndARead() async {
        await harness.coordinator.handle(.appActivated(notes, FocusGeneration(raw: 1)))
        let entry = harness.entries.first { $0.app.key == notes.key }!
        harness.activator.fail(.cg(9), with: AXActivationError.unknownWindow(.cg(9)))
        let reads = harness.source.reads(of: notes)
        await harness.coordinator.activate(entry)
        XCTAssertNotNil(harness.entries.first { $0.id == entry.id }, "no evidence the window is gone")
        XCTAssertEqual(harness.source.reads(of: notes), reads + 1)
    }

    func testActivationTimeoutKeepsTheEntry() async {
        await harness.coordinator.handle(.appActivated(notes, FocusGeneration(raw: 1)))
        let entry = harness.entries.first { $0.app.key == notes.key }!
        harness.activator.fail(.cg(9), with: AXActivationError.unconfirmed)
        await harness.coordinator.activate(entry)
        XCTAssertNotNil(harness.entries.first { $0.id == entry.id })
    }

    // MARK: Panel visibility (H) and the sweep (F)

    func testRemovalsWaitForThePanelToClose() async {
        harness.source.set([window(9, notes, title: "Groceries", focused: true), window(10, notes, title: "Todo")], for: notes)
        await harness.coordinator.handle(.appActivated(notes, FocusGeneration(raw: 1)))
        harness.coordinator.setPanelVisible(true)
        harness.source.set([window(9, notes, title: "Groceries", focused: true)], for: notes)
        await harness.coordinator.handle(.periodic)
        XCTAssertTrue(harness.entries.contains { $0.key == .cg(10) }, "nothing vanishes under the selection")

        harness.coordinator.setPanelVisible(false)
        XCTAssertFalse(harness.entries.contains { $0.key == .cg(10) })
    }

    func testAppsMissingFromTheProcessTableAreSweptOnlyWithAWindowServerRead() async {
        await activateChrome()
        await harness.coordinator.handle(.appActivated(notes, FocusGeneration(raw: 2)))
        XCTAssertEqual(harness.entries.map(\.app.key).contains(notes.key), true)

        harness.directory.set(apps: [chrome])
        harness.setLive(nil)
        await harness.coordinator.handle(.periodic)
        XCTAssertTrue(harness.entries.contains { $0.app.key == notes.key }, "no WindowServer read, no evidence (L5)")

        harness.setLive([1, 2, 3])
        await harness.coordinator.handle(.periodic)
        XCTAssertFalse(harness.entries.contains { $0.app.key == notes.key })
    }

    func testWindowGoneFromTheWindowServerIsStruckOutOverThreeSweeps() async {
        // Window 9 sits on another Space: AX reads no longer list it, which
        // is not evidence (G); only the WindowServer's silence counts, and
        // only three times in a row.
        harness.source.set([WindowSnapshot(key: .cg(9), app: notes, title: "Groceries", subrole: "AXStandardWindow",
                                           isMinimized: false, isOnActiveSpace: false),
                            window(10, notes, title: "Todo", focused: true)], for: notes)
        harness.setLive([1, 2, 3, 9, 10])
        await harness.coordinator.handle(.appActivated(notes, FocusGeneration(raw: 1)))
        XCTAssertEqual(harness.entries.filter { $0.app.key == notes.key }.count, 2)

        harness.source.set([window(10, notes, title: "Todo", focused: true)], for: notes)
        harness.setLive([1, 2, 3, 10])
        for sweep in 1...2 {
            await harness.coordinator.handle(.periodic)
            XCTAssertTrue(harness.entries.contains { $0.key == .cg(9) }, "sweep \(sweep)")
        }
        await harness.coordinator.handle(.periodic)
        XCTAssertFalse(harness.entries.contains { $0.key == .cg(9) })
        XCTAssertTrue(harness.entries.contains { $0.key == .cg(10) })
    }

    func testRebuildStartsOverAndReadsEverything() async {
        await activateChrome()
        await harness.coordinator.rebuild()
        XCTAssertEqual(chromeRows.map(\.title), ["GitHub", "Docs", "Mail"])
        XCTAssertEqual(chromeRows.map(\.count), [3, 2, nil])
    }
}

@MainActor
final class SystemMonitorTests: XCTestCase {
    func testWakeAndSpaceNotificationsReachTheHandlers() {
        let monitor = SystemEventMonitor()
        var events: [String] = []
        monitor.onWake = { events.append("wake") }
        monitor.onActiveSpaceChanged = { events.append("space") }
        monitor.onScreensChanged = { events.append("screens") }
        monitor.onSessionResigned = { events.append("resign") }
        monitor.onSessionResumed = { events.append("resume") }
        monitor.start()
        defer { monitor.stop() }

        let workspace = NSWorkspace.shared.notificationCenter
        workspace.post(name: NSWorkspace.didWakeNotification, object: nil)
        workspace.post(name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
        workspace.post(name: NSWorkspace.sessionDidResignActiveNotification, object: nil)
        workspace.post(name: NSWorkspace.sessionDidBecomeActiveNotification, object: nil)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        XCTAssertEqual(events, ["wake", "space", "screens", "resign", "resume"])

        monitor.stop()
        workspace.post(name: NSWorkspace.didWakeNotification, object: nil)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        XCTAssertEqual(events.count, 5)
    }

    func testAccessibilityWatchReportsBothEdges() async throws {
        let trusted = OSAllocatedUnfairLock(initialState: true)
        let watch = AccessibilityWatch(isTrusted: { trusted.withLock { $0 } }, interval: .milliseconds(10))
        var seen: [Bool] = []
        watch.onChange = { seen.append($0) }
        watch.start()
        defer { watch.stop() }

        try await Task.sleep(for: .milliseconds(40))
        trusted.withLock { $0 = false }
        try await Task.sleep(for: .milliseconds(40))
        trusted.withLock { $0 = true }
        try await Task.sleep(for: .milliseconds(40))
        XCTAssertEqual(seen, [true, false, true])
    }
}
