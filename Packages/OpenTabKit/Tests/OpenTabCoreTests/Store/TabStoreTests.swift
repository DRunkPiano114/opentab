import XCTest
@testable import OpenTabCore

/// The sixteen cases of `reference/reconciliation.md`, in order, then the
/// behaviours they rely on.
final class TabStoreTests: XCTestCase {
    let xcode = app("Xcode", pid: 200)
    let github = scripted(chrome, "w1")
    let docs = scripted(chrome, "w2")

    private func w1(_ h: inout StoreHarness) -> EntryID { .window(.cg(1)) }

    // MARK: 1-3 Empty reads and strikes

    func test01EmptyReadWithWindowAliveInWindowServerDoesNotDelete() {
        var h = StoreHarness()
        h.windows([chromeWindow(1, "GitHub")], for: chrome)
        XCTAssertEqual(h.windows([], for: chrome).disposition, .rejectedEmpty)
        h.sweep(live: [1])
        XCTAssertEqual(h.shownKeys, [.cg(1)])
        XCTAssertEqual(h.store.entries[.window(.cg(1))]?.missingStrikes, 0)
    }

    func test02MissingForThresholdMinusOneSweepsIsKept() {
        var h = StoreHarness()
        h.windows([chromeWindow(1, "GitHub")], for: chrome)
        for _ in 0..<(h.store.configuration.missingStrikeThreshold - 1) {
            h.sweep(live: [999])
        }
        XCTAssertEqual(h.shownKeys, [.cg(1)])
        XCTAssertEqual(h.store.entries[.window(.cg(1))]?.missingStrikes, 2)
    }

    func test03MissingForThresholdSweepsIsRemoved() {
        var h = StoreHarness()
        h.windows([chromeWindow(1, "GitHub"), chromeWindow(2, "Docs")], for: chrome)
        for _ in 0..<h.store.configuration.missingStrikeThreshold {
            h.sweep(live: [2])
        }
        XCTAssertEqual(h.shownKeys, [.cg(2)])
    }

    func testStrikesResetWhenTheWindowIsSeenAgain() {
        var h = StoreHarness()
        h.windows([chromeWindow(1, "GitHub")], for: chrome)
        h.sweep(live: [999])
        h.sweep(live: [999])
        h.sweep(live: [1])
        h.sweep(live: [999])
        h.sweep(live: [999])
        XCTAssertEqual(h.shownKeys, [.cg(1)], "a sighting between misses breaks the run")
    }

    func testUnknownOrEmptyWindowServerTableNeverStrikes() {
        var h = StoreHarness()
        h.windows([chromeWindow(1, "GitHub")], for: chrome)
        for _ in 0..<5 {
            h.sweep(live: nil)
            h.sweep(live: [])
        }
        XCTAssertEqual(h.store.entries[.window(.cg(1))]?.missingStrikes, 0)
    }

    // MARK: 4 Generation guard

    func test04StaleGenerationResultIsDropped() {
        var h = StoreHarness()
        h.windows([chromeWindow(1, "GitHub")], for: chrome)
        h.tabs([tab(github, "t1", "GitHub", active: true)], for: chrome)
        let before = h.store.entries

        let windowStamp = h.store.beginRead(for: chrome, kind: .windows)
        let tabStamp = h.store.beginRead(for: chrome, kind: .tabs)
        h.store.advanceGeneration(to: h.store.currentGeneration.next())
        let windows = h.store.applyWindows([chromeWindow(1, "Elsewhere"), chromeWindow(5, "New")], for: chrome,
                                           isHidden: false, bumpFocused: true, stamp: windowStamp, now: h.now)
        XCTAssertEqual(windows.disposition, .staleGeneration)
        let tabs = h.store.applyTabs([tab(docs, "t9", "Docs", active: true)], for: chrome, stability: .stable,
                                     stamp: tabStamp, now: h.now)
        XCTAssertEqual(tabs.disposition, .staleGeneration)
        XCTAssertEqual(h.store.entries, before)
        XCTAssertEqual(h.store.droppedReadCount, 2)
    }

    func testSupersededReadIsDropped() {
        var h = StoreHarness()
        let older = h.store.beginRead(for: chrome, kind: .windows)
        let newer = h.store.beginRead(for: chrome, kind: .windows)
        XCTAssertEqual(h.store.applyWindows([chromeWindow(2, "New")], for: chrome, isHidden: false,
                                            stamp: newer, now: h.now).disposition, .applied)
        XCTAssertEqual(h.store.applyWindows([chromeWindow(1, "Old")], for: chrome, isHidden: false,
                                            stamp: older, now: h.now).disposition, .superseded)
        XCTAssertEqual(h.shownKeys, [.cg(2)])
    }

    func testWindowAndTabReadsOfOneAppDoNotSupersedeEachOther() {
        var h = StoreHarness()
        let windowStamp = h.store.beginRead(for: chrome, kind: .windows)
        let tabStamp = h.store.beginRead(for: chrome, kind: .tabs)
        XCTAssertEqual(h.store.applyWindows([chromeWindow(1, "GitHub")], for: chrome, isHidden: false,
                                            stamp: windowStamp, now: h.now).disposition, .applied)
        XCTAssertEqual(h.store.applyTabs([tab(github, "t1", "GitHub", active: true)], for: chrome,
                                         stability: .stable, stamp: tabStamp, now: h.now).disposition, .applied)
        XCTAssertEqual(h.shownKeys, [github])
    }

    func testGenerationOnlyMovesForward() {
        var store = TabStore()
        store.advanceGeneration(to: FocusGeneration(raw: 5))
        store.advanceGeneration(to: FocusGeneration(raw: 3))
        XCTAssertEqual(store.currentGeneration.raw, 5)
    }

    // MARK: 5-7 Claim rules

    func test05RulesOneAndThreeBothAvailablePickTitle() {
        var h = StoreHarness()
        h.windows([chromeWindow(1, "GitHub")], for: chrome)
        XCTAssertTrue(h.store.resolve(window: .cg(1), toScriptWindow: github, now: h.now).claims.isEmpty)
        let result = h.tabs([tab(github, "t1", "GitHub", active: true)], for: chrome)
        XCTAssertEqual(result.claims, [Claim(window: .window(.cg(1)), scriptWindow: github, rule: .title)])
    }

    func test05RulesTwoAndThreeBothAvailablePickElimination() {
        var h = StoreHarness()
        h.windows([chromeWindow(1, "")], for: chrome)
        _ = h.store.resolve(window: .cg(1), toScriptWindow: github, now: h.now)
        let result = h.tabs([tab(github, "t1", "Loading", active: true)], for: chrome)
        XCTAssertEqual(result.claims.map(\.rule), [.elimination])
    }

    func testRuleThreeAloneClaimsByResolution() {
        var h = StoreHarness()
        h.windows([chromeWindow(1, "Something else entirely")], for: chrome)
        h.tabs([tab(github, "t1", "GitHub", active: true)], for: chrome)
        XCTAssertEqual(h.shownKeys.count, 2, "no title match, no claim yet")
        let result = h.store.resolve(window: .cg(1), toScriptWindow: github, now: h.now)
        XCTAssertEqual(result.claims.map(\.rule), [.resolution])
        XCTAssertEqual(h.shownKeys, [github])
        XCTAssertEqual(h.store.claimedWindow(for: github), .cg(1))
    }

    func testTitleClaimDisagreeingWithResolutionClaimsNothing() {
        var h = StoreHarness()
        h.windows([chromeWindow(1, "GitHub")], for: chrome)
        _ = h.store.resolve(window: .cg(1), toScriptWindow: docs, now: h.now)
        let result = h.tabs([tab(github, "t1", "GitHub", active: true), tab(docs, "t2", "Docs", active: true)],
                            for: chrome)
        XCTAssertTrue(result.claims.isEmpty)
        XCTAssertEqual(h.store.claimConflictCount, 1)
        XCTAssertEqual(h.shownKeys.count, 3)
    }

    func test06BlankWindowWithSeveralUnownedScriptWindowsIsNotClaimed() {
        var h = StoreHarness()
        h.windows([chromeWindow(1, "")], for: chrome)
        let result = h.tabs([tab(github, "t1", "GitHub", active: true), tab(docs, "t2", "Docs", active: true)],
                            for: chrome)
        XCTAssertTrue(result.claims.isEmpty)
        XCTAssertEqual(Set(h.shownKeys), [.cg(1), github, docs])
    }

    func testTwoBlankWindowsWithOneScriptWindowAreNotClaimed() {
        var h = StoreHarness()
        h.windows([chromeWindow(1, ""), chromeWindow(2, "")], for: chrome)
        let result = h.tabs([tab(github, "t1", "GitHub", active: true)], for: chrome)
        XCTAssertTrue(result.claims.isEmpty, "which blank window the script window owns is a guess")
    }

    func testTitleEvidenceBeatsEliminationAcrossWindows() {
        var h = StoreHarness()
        h.windows([chromeWindow(1, ""), chromeWindow(2, "GitHub")], for: chrome)
        let result = h.tabs([tab(github, "t1", "GitHub", active: true)], for: chrome)
        XCTAssertEqual(result.claims, [Claim(window: .window(.cg(2)), scriptWindow: github, rule: .title)],
                       "the blank window discovered first must not take the script window by elimination")
        XCTAssertEqual(Set(h.shownKeys), [.cg(1), github])
    }

    func test07ReAddWithinFiveSecondsOfClaimCountsAFlap() {
        var h = StoreHarness()
        h.windows([chromeWindow(1, "GitHub")], for: chrome)
        let claimed = h.tabs([tab(github, "t1", "GitHub", active: true)], for: chrome)
        XCTAssertEqual(claimed.claims.count, 1)
        let rank = h.store.promotedTab(in: github)!.discoveryRank

        h.advance(.seconds(1))
        let released = h.tabs([tab(docs, "t2", "Docs", active: true)], for: chrome)
        XCTAssertEqual(released.releasedWindows, [.window(.cg(1))])
        XCTAssertEqual(h.shownKeys, [docs], "a released window waits for a window read to list it")

        h.advance(.seconds(2))
        h.windows([chromeWindow(1, "GitHub")], for: chrome)
        XCTAssertEqual(h.store.flapCount, 1)
        XCTAssertEqual(h.store.entries[.window(.cg(1))]?.discoveryRank, rank, "the row comes back where it was")
    }

    func testReAddAfterFiveSecondsIsNotAFlap() {
        var h = StoreHarness()
        h.windows([chromeWindow(1, "GitHub")], for: chrome)
        h.tabs([tab(github, "t1", "GitHub", active: true)], for: chrome)
        h.advance(.seconds(1))
        h.tabs([tab(docs, "t2", "Docs", active: true)], for: chrome)
        h.advance(.seconds(5))
        h.windows([chromeWindow(1, "GitHub")], for: chrome)
        XCTAssertEqual(h.store.flapCount, 0)
        XCTAssertTrue(h.shownKeys.contains(.cg(1)))
    }

    // MARK: 8-9 Deferred removal

    func test08RemovalWhilePanelVisibleIsQueued() {
        var h = StoreHarness()
        h.windows([chromeWindow(1, "GitHub"), chromeWindow(2, "Docs")], for: chrome)
        h.tabs([tab(github, "t1", "GitHub", active: true)], for: chrome)
        let before = h.shownIDs
        h.store.setPanelVisible(true)
        h.windows([chromeWindow(1, "GitHub")], for: chrome)
        XCTAssertEqual(h.shownIDs, before)
        h.store.activationFailed(.window(.cg(2)))
        XCTAssertEqual(h.shownIDs, before)
        h.store.removeApp(chrome.key)
        XCTAssertEqual(h.shownIDs, before)
    }

    func test09ClosingThePanelAppliesTheQueue() {
        var h = StoreHarness()
        h.windows([chromeWindow(1, "GitHub"), chromeWindow(2, "Docs")], for: chrome)
        h.store.setPanelVisible(true)
        h.windows([chromeWindow(1, "GitHub")], for: chrome)
        XCTAssertTrue(h.store.setPanelVisible(false, now: h.now))
        XCTAssertEqual(h.shownKeys, [.cg(1)])
    }

    func testQueuedRemovalIsCancelledWhenTheWindowIsSeenAgain() {
        var h = StoreHarness()
        h.windows([chromeWindow(1, "GitHub"), chromeWindow(2, "Docs")], for: chrome)
        h.store.setPanelVisible(true)
        h.windows([chromeWindow(1, "GitHub")], for: chrome)
        h.windows([chromeWindow(1, "GitHub"), chromeWindow(2, "Docs")], for: chrome)
        h.store.setPanelVisible(false, now: h.now)
        XCTAssertEqual(Set(h.shownKeys), [.cg(1), .cg(2)])
    }

    func testClaimsWaitForThePanelToClose() {
        var h = StoreHarness()
        h.windows([chromeWindow(1, "GitHub")], for: chrome)
        h.store.setPanelVisible(true)
        XCTAssertTrue(h.tabs([tab(github, "t1", "GitHub", active: true)], for: chrome).claims.isEmpty)
        XCTAssertEqual(Set(h.shownKeys), [.cg(1), github], "both rows stay while the panel is up")
        h.store.setPanelVisible(false, now: h.now)
        XCTAssertEqual(h.shownKeys, [github])
    }

    // MARK: 10-11 Direct evidence

    func test10TerminatedAppIsRemovedImmediately() {
        var h = StoreHarness()
        h.windows([chromeWindow(1, "GitHub")], for: chrome)
        h.tabs([tab(github, "t1", "GitHub", active: true), tab(github, "t2", "Issues")], for: chrome)
        h.windows([window(3, xcode)], for: xcode)
        XCTAssertTrue(h.store.removeApp(chrome.key))
        XCTAssertEqual(h.shownKeys, [.cg(3)])
        XCTAssertTrue(h.store.tabs(in: github).isEmpty)
        XCTAssertNil(h.store.claimedWindow(for: github))
    }

    func testSweepWithProcessTableRemovesGoneApps() {
        var h = StoreHarness()
        h.windows([chromeWindow(1, "GitHub")], for: chrome)
        h.windows([window(3, xcode)], for: xcode)
        XCTAssertTrue(h.sweep(live: [1, 3], running: [xcode.key]))
        XCTAssertEqual(h.shownKeys, [.cg(3)])
    }

    func test11ActivationFailureRemovesTheEntryImmediately() {
        var h = StoreHarness()
        h.windows([chromeWindow(1, "GitHub")], for: chrome)
        h.tabs([tab(github, "t1", "GitHub", active: true), tab(github, "t2", "Issues")], for: chrome)
        XCTAssertTrue(h.store.activationFailed(EntryID(key: github, tabToken: "t2")))
        XCTAssertEqual(h.store.tabs(in: github).map(\.id.tabToken), ["t1"])
        XCTAssertFalse(h.store.activationFailed(EntryID(key: github, tabToken: "t2")))
    }

    func testRemovingThePromotedTabKeepsARowForTheWindow() {
        var h = StoreHarness()
        h.windows([chromeWindow(1, "GitHub")], for: chrome)
        h.tabs([tab(github, "t1", "GitHub", active: true), tab(github, "t2", "Issues")], for: chrome)
        h.store.activationFailed(EntryID(key: github, tabToken: "t1"))
        XCTAssertEqual(h.shownIDs, [EntryID(key: github, tabToken: "t2")])
    }

    // MARK: 12 Ordering

    func test12OrderIsIdenticalAcrossRendersAndStores() {
        var a = StoreHarness(), b = StoreHarness()
        let windows = (1...40).map { chromeWindow(UInt32($0), "Page \($0)") }
        let tabs = (1...40).map { tab(scripted(chrome, "w\($0)"), "t\($0)", "Page \($0)", active: true) }
        a.windows(windows, for: chrome)
        a.tabs(tabs, for: chrome)
        b.windows(windows, for: chrome)
        b.tabs(tabs, for: chrome)
        let first = a.shownIDs
        XCTAssertEqual(first.count, 40)
        for _ in 0..<20 { XCTAssertEqual(a.shownIDs, first) }
        XCTAssertEqual(b.shownIDs, first)
        XCTAssertEqual(first.map(\.tabToken), (1...40).map { "t\($0)" }, "discovery order is the tie-break")
    }

    func testClaimKeepsTheRowWhereTheUserSawIt() {
        var h = StoreHarness()
        h.windows([chromeWindow(1, "GitHub"), chromeWindow(2, "Docs")], for: chrome)
        h.windows([window(3, xcode)], for: xcode)
        h.tabs([tab(docs, "t2", "Docs", active: true)], for: chrome)
        XCTAssertEqual(h.shownKeys, [.cg(1), docs, .cg(3)])
    }

    func testSwitchingTheActiveTabDoesNotMoveTheRow() {
        var h = StoreHarness()
        h.windows([window(3, xcode)], for: xcode)
        h.windows([chromeWindow(1, "GitHub", focused: true)], for: chrome, bumpFocused: true)
        h.tabs([tab(github, "t1", "GitHub", active: true), tab(github, "t2", "Issues")], for: chrome)
        XCTAssertEqual(h.shownIDs.first, EntryID(key: github, tabToken: "t1"))
        h.tabs([tab(github, "t1", "GitHub"), tab(github, "t2", "Issues", active: true)], for: chrome)
        XCTAssertEqual(h.shownIDs, [EntryID(key: github, tabToken: "t2"), .window(.cg(3))])
    }

    func testFocusBumpOnAClaimedWindowMovesItsTabRow() {
        var h = StoreHarness()
        h.windows([chromeWindow(1, "GitHub")], for: chrome)
        h.tabs([tab(github, "t1", "GitHub", active: true)], for: chrome)
        h.windows([window(3, xcode, focused: true)], for: xcode, bumpFocused: true)
        XCTAssertEqual(h.shownKeys, [.cg(3), github])
        h.windows([chromeWindow(1, "GitHub", focused: true)], for: chrome, bumpFocused: true)
        XCTAssertEqual(h.shownKeys, [github, .cg(3)])
    }

    // MARK: 13 Other Spaces

    func test13WindowOnAnotherSpaceSurvivesReadsThatOmitIt() {
        var h = StoreHarness()
        h.windows([chromeWindow(1, "GitHub"), chromeWindow(2, "Docs", onActiveSpace: false)], for: chrome)
        h.windows([chromeWindow(1, "GitHub")], for: chrome)
        XCTAssertEqual(Set(h.shownKeys), [.cg(1), .cg(2)])
        XCTAssertEqual(h.windows([], for: chrome).disposition, .rejectedEmpty)
        XCTAssertEqual(Set(h.shownKeys), [.cg(1), .cg(2)])
        h.windows([chromeWindow(1, "GitHub"), chromeWindow(2, "Docs", onActiveSpace: true)], for: chrome)
        h.windows([chromeWindow(1, "GitHub")], for: chrome)
        XCTAssertEqual(h.shownKeys, [.cg(1)], "back on the active Space, omission is evidence again")
    }

    // MARK: 14-16 Chrome-shaped titles

    func test14ChromeWindowTitleIsClaimedByItsTab() {
        var h = StoreHarness()
        h.windows([chromeWindow(1, "GitHub")], for: chrome)
        let result = h.tabs([tab(github, "t1", "GitHub", active: true)], for: chrome)
        XCTAssertEqual(result.claims, [Claim(window: .window(.cg(1)), scriptWindow: github, rule: .title)])
        XCTAssertEqual(h.shownIDs, [EntryID(key: github, tabToken: "t1")])
    }

    func test15ThreeChromeWindowsGiveExactlyThreeRows() {
        var h = StoreHarness()
        let pages = ["GitHub", "Docs", "Mail"]
        h.windows(pages.enumerated().map { chromeWindow(UInt32($0 + 1), $1) }, for: chrome)
        var tabs: [TabSnapshot] = []
        for (i, page) in pages.enumerated() {
            let key = scripted(chrome, "w\(i + 1)")
            tabs.append(tab(key, "a\(i)", page, active: true))
            tabs.append(tab(key, "b\(i)", "\(page) background"))
        }
        let result = h.tabs(tabs, for: chrome)
        XCTAssertEqual(result.claims.count, 3)
        XCTAssertEqual(h.shownKeys.count, 3)
        XCTAssertEqual(h.store.groupCounts().displayCount(forApp: chrome.key), 3)
        XCTAssertEqual(h.store.groupCounts().byWindowKey[scripted(chrome, "w1")], 2)
        for _ in 0..<3 {
            h.windows(pages.enumerated().map { chromeWindow(UInt32($0 + 1), $1) }, for: chrome)
            h.tabs(tabs, for: chrome)
            XCTAssertEqual(h.shownKeys.count, 3, "repeated reads must not resurrect the window rows")
        }
        XCTAssertEqual(h.store.flapCount, 0)
    }

    func test16ShortIdenticalTitlesAcrossWindowsAreNotClaimed() {
        var h = StoreHarness()
        h.windows([chromeWindow(1, "新标签页"), chromeWindow(2, "新标签页")], for: chrome)
        let result = h.tabs([tab(github, "t1", "新标签页", active: true), tab(docs, "t2", "新标签页", active: true)],
                            for: chrome)
        XCTAssertTrue(result.claims.isEmpty)
        XCTAssertEqual(h.shownKeys.count, 4, "ambiguity keeps both rows until the titles diverge")
        XCTAssertEqual(h.store.flapCount, 0)
    }

    // MARK: Script windows and their claimed windows

    func testScriptWindowGoneFromATabReadClosesItsTabs() {
        var h = StoreHarness()
        h.windows([chromeWindow(1, "GitHub"), chromeWindow(2, "Docs")], for: chrome)
        h.tabs([tab(github, "t1", "GitHub", active: true), tab(docs, "t2", "Docs", active: true)], for: chrome)
        h.tabs([tab(github, "t1", "GitHub", active: true)], for: chrome)
        XCTAssertTrue(h.store.tabs(in: docs).isEmpty)
        XCTAssertEqual(h.shownKeys, [github])
        h.windows([chromeWindow(1, "GitHub")], for: chrome)
        XCTAssertEqual(h.shownKeys, [github], "the closed window is not resurrected")
    }

    func testWindowGoneFromAWindowReadClosesItsScriptWindow() {
        var h = StoreHarness()
        h.windows([chromeWindow(1, "GitHub"), chromeWindow(2, "Docs")], for: chrome)
        h.tabs([tab(github, "t1", "GitHub", active: true), tab(docs, "t2", "Docs", active: true)], for: chrome)
        h.windows([chromeWindow(1, "GitHub")], for: chrome)
        XCTAssertEqual(h.shownKeys, [github])
        XCTAssertTrue(h.store.tabs(in: docs).isEmpty)
    }

    func testStruckClaimedWindowTakesItsTabsWithIt() {
        var h = StoreHarness()
        h.windows([chromeWindow(1, "GitHub")], for: chrome)
        h.tabs([tab(github, "t1", "GitHub", active: true)], for: chrome)
        for _ in 0..<3 { h.sweep(live: [999]) }
        XCTAssertTrue(h.store.isEmpty)
    }

    func testProviderUnavailableReleasesWindowsUntilTheNextWindowRead() {
        var h = StoreHarness()
        h.windows([chromeWindow(1, "GitHub")], for: chrome)
        h.tabs([tab(github, "t1", "GitHub", active: true)], for: chrome)
        let result = h.store.removeTabs(for: chrome)
        XCTAssertEqual(result.releasedWindows, [.window(.cg(1))])
        XCTAssertTrue(h.shownKeys.isEmpty)
        h.advance(.seconds(1))
        h.windows([chromeWindow(1, "GitHub")], for: chrome)
        XCTAssertEqual(h.shownKeys, [.cg(1)])
        XCTAssertEqual(h.store.flapCount, 0, "a release the caller asked for is not a misfiring claim rule")
    }

    func testClaimedWindowStateFlowsToItsTabs() {
        var h = StoreHarness()
        h.windows([chromeWindow(1, "GitHub")], for: chrome)
        h.tabs([tab(github, "t1", "GitHub", active: true), tab(github, "t2", "Issues")], for: chrome)
        let minimized = WindowSnapshot(key: .cg(1), app: chrome, title: "GitHub - Google Chrome",
                                       subrole: "AXStandardWindow", isMinimized: true, isOnActiveSpace: false)
        XCTAssertTrue(h.windows([minimized], for: chrome, isHidden: true).changed)
        for entry in h.store.tabs(in: github) {
            XCTAssertTrue(entry.isMinimized)
            XCTAssertFalse(entry.isOnActiveSpace)
            XCTAssertTrue(entry.isHidden)
        }
        h.store.setHidden(false, for: chrome.key)
        XCTAssertFalse(h.store.promotedTab(in: github)!.isHidden)
    }

    func testRecencyOfATabSurvivesReleaseAndReAdd() {
        var h = StoreHarness()
        h.windows([window(3, xcode)], for: xcode)
        h.windows([chromeWindow(1, "GitHub")], for: chrome)
        h.tabs([tab(github, "t1", "GitHub", active: true)], for: chrome)
        h.store.bumpFocus(EntryID(key: github, tabToken: "t1"))
        XCTAssertEqual(h.shownKeys, [github, .cg(3)])
        _ = h.store.removeTabs(for: chrome)
        h.advance(.seconds(6))
        h.windows([chromeWindow(1, "GitHub")], for: chrome)
        XCTAssertEqual(h.shownKeys, [.cg(1), .cg(3)])
    }

    func testTabsInWindowFollowProviderOrder() {
        var h = StoreHarness()
        h.tabs([tab(github, "t3", "C"), tab(github, "t1", "A", active: true), tab(github, "t2", "B")], for: chrome)
        XCTAssertEqual(h.store.tabs(in: github).map(\.id.tabToken), ["t3", "t1", "t2"])
        h.tabs([tab(github, "t1", "A", active: true), tab(github, "t2", "B"), tab(github, "t3", "C")], for: chrome)
        XCTAssertEqual(h.store.tabs(in: github).map(\.id.tabToken), ["t1", "t2", "t3"])
    }

    func testPrivateTabsAreDroppedUnlessOptedIn() {
        var h = StoreHarness()
        h.tabs([tab(github, "t1", "GitHub", active: true), tab(github, "t2", "Secret", isPrivate: true),
                tab(docs, "t3", "Incognito", active: true, isPrivate: true)], for: chrome)
        XCTAssertEqual(h.store.tabs(in: github).map(\.id.tabToken), ["t1"])
        XCTAssertTrue(h.store.tabs(in: docs).isEmpty, "a window with only private tabs is not listed")

        var configuration = TabStore.Configuration()
        configuration.includesPrivateTabs = true
        var optedIn = StoreHarness(configuration: configuration)
        optedIn.tabs([tab(github, "t1", "GitHub", active: true), tab(github, "t2", "Secret", isPrivate: true)], for: chrome)
        XCTAssertEqual(optedIn.store.tabs(in: github).count, 2)
    }

    func testEmptyTabReadKeepsExistingEntries() {
        var h = StoreHarness()
        h.tabs([tab(github, "t1", "GitHub", active: true)], for: chrome)
        XCTAssertEqual(h.tabs([], for: chrome).disposition, .rejectedEmpty)
        XCTAssertEqual(h.store.tabs(in: github).count, 1)
    }

    // MARK: Positional tokens (Safari, H11)

    func testPositionalTokensFollowTheTabWhenItIsDragged() {
        var h = StoreHarness()
        let win = scripted(safariApp, "10")
        h.tabs([tab(win, "0", "Apple"), tab(win, "1", "Swift Forums", active: true)], for: safariApp, stability: .positional)
        h.store.bumpFocus(EntryID(key: win, tabToken: "0"))
        let appleTick = h.store.entries[EntryID(key: win, tabToken: "0")]!.focusTick
        h.tabs([tab(win, "0", "Swift Forums", active: true), tab(win, "1", "Apple")], for: safariApp, stability: .positional)
        XCTAssertEqual(h.store.entries[EntryID(key: win, tabToken: "1")]?.title, "Apple")
        XCTAssertEqual(h.store.entries[EntryID(key: win, tabToken: "1")]?.focusTick, appleTick)
        XCTAssertEqual(h.store.tabs(in: win).count, 2)
    }

    func testPositionalNavigationKeepsTheIdentity() {
        var h = StoreHarness()
        let win = scripted(safariApp, "10")
        h.tabs([tab(win, "0", "Apple", active: true)], for: safariApp, stability: .positional)
        let rank = h.store.entries[EntryID(key: win, tabToken: "0")]!.discoveryRank
        h.tabs([tab(win, "0", "Apple Developer", active: true)], for: safariApp, stability: .positional)
        XCTAssertEqual(h.store.entries[EntryID(key: win, tabToken: "0")]?.discoveryRank, rank)
        XCTAssertEqual(h.store.tabs(in: win).count, 1)
    }

    func testPositionalCloseShiftsTheRemainingTabs() {
        var h = StoreHarness()
        let win = scripted(safariApp, "10")
        h.tabs([tab(win, "0", "Apple"), tab(win, "1", "Swift Forums"), tab(win, "2", "Docs", active: true)],
               for: safariApp, stability: .positional)
        let docsRank = h.store.entries[EntryID(key: win, tabToken: "2")]!.discoveryRank
        h.tabs([tab(win, "0", "Apple"), tab(win, "1", "Docs", active: true)], for: safariApp, stability: .positional)
        XCTAssertEqual(h.store.tabs(in: win).map(\.title), ["Apple", "Docs"])
        XCTAssertEqual(h.store.entries[EntryID(key: win, tabToken: "1")]?.discoveryRank, docsRank)
    }

    func testPositionalCloseWhilePanelVisibleKeepsTheMovedTab() {
        var h = StoreHarness()
        let win = scripted(safariApp, "10")
        h.tabs([tab(win, "0", "Apple"), tab(win, "1", "Swift Forums"), tab(win, "2", "Docs", active: true)],
               for: safariApp, stability: .positional)
        h.store.setPanelVisible(true)
        h.tabs([tab(win, "0", "Apple"), tab(win, "1", "Docs", active: true)], for: safariApp, stability: .positional)
        h.store.setPanelVisible(false, now: h.now)
        XCTAssertEqual(h.store.tabs(in: win).map(\.title), ["Apple", "Docs"])
    }

    func testStableTokensAreIdentityEvenWhenTitlesMove() {
        var h = StoreHarness()
        h.tabs([tab(github, "t1", "Apple"), tab(github, "t2", "Swift", active: true)], for: chrome)
        h.tabs([tab(github, "t1", "Swift", active: true), tab(github, "t2", "Apple")], for: chrome)
        XCTAssertEqual(h.store.entries[EntryID(key: github, tabToken: "t1")]?.title, "Swift")
    }

    // MARK: Group counts

    func testGroupCountsCountTabsPerScriptWindowAndRowsPerApp() {
        var h = StoreHarness()
        h.windows([chromeWindow(1, "GitHub"), chromeWindow(2, "Plain")], for: chrome)
        h.tabs([tab(github, "t1", "GitHub", active: true), tab(github, "t2", "Issues"), tab(github, "t3", "PRs")],
               for: chrome)
        let counts = h.store.groupCounts()
        XCTAssertEqual(counts.byWindowKey[github], 3)
        XCTAssertEqual(counts.byWindowKey[.cg(2)], 1)
        XCTAssertNil(counts.byWindowKey[.cg(1)], "a claimed window entry is not a row")
        XCTAssertEqual(counts.displayCount(forApp: chrome.key), 2)
    }

    func testIgnoredAppsNeverEnterTheStore() {
        var h = StoreHarness()
        let dock = AppInfo(bundleID: "com.apple.dock", pid: 5, localizedName: "Dock")
        XCTAssertEqual(h.windows([window(9, dock)], for: dock).disposition, .rejectedEmpty)
        XCTAssertTrue(h.store.isEmpty)
    }

    func testRemoveAllForgetsEverything() {
        var h = StoreHarness()
        h.windows([chromeWindow(1, "GitHub")], for: chrome)
        h.tabs([tab(github, "t1", "GitHub", active: true)], for: chrome)
        h.store.removeAll()
        XCTAssertTrue(h.store.isEmpty)
        h.windows([chromeWindow(1, "GitHub")], for: chrome)
        XCTAssertEqual(h.shownKeys, [.cg(1)])
        XCTAssertEqual(h.store.flapCount, 0)
    }
}
