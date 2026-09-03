import AppKit
import OpenTabAX
import OpenTabCore
import OpenTabScript
import XCTest
@testable import OpenTab

/// A provider that reads over Accessibility: no Apple Events consent, and an
/// empty read that means "no tab strip" rather than "no answer".
private final class FakeAccessibilityProvider: TabProvider, TabCloser, AccessibilityTabReads, @unchecked Sendable {
    let bundleIDs: [String]
    let tokenStability = TokenStability.positional

    private let lock = NSLock()
    private var tabs: [TabSnapshot] = []
    private(set) var closed: [TabSnapshot] = []
    private var closeError: (any Error)?

    init(bundleIDs: [String]) { self.bundleIDs = bundleIDs }

    func set(tabs: [TabSnapshot]) { lock.withLock { self.tabs = tabs } }
    func failClose(with error: (any Error)?) { lock.withLock { closeError = error } }

    func readTabs(for app: AppInfo, deadline: ContinuousClock.Instant) async throws -> [TabSnapshot] {
        lock.withLock { tabs }
    }

    func activate(_ tab: TabSnapshot, deadline: ContinuousClock.Instant) async throws {}

    func close(_ tab: TabSnapshot, deadline: ContinuousClock.Instant) async throws {
        let error = lock.withLock { () -> (any Error)? in
            closed.append(tab)
            // The coordinator re-keys a window to its scripted form before
            // the store sees it, so a close arrives named that way; the token
            // is what identifies the tab here.
            if closeError == nil { tabs.removeAll { $0.token == tab.token } }
            return closeError
        }
        if let error { throw error }
    }
}

@MainActor
final class DetailPaneTests: XCTestCase {
    private var source: FakeWindowSource!
    private var directory: FakeAppDirectory!
    private var gate: FakeAutomationGate!

    override func setUp() {
        source = FakeWindowSource()
        directory = FakeAppDirectory()
        gate = FakeAutomationGate()
    }

    private func makeCoordinator(_ provider: any TabProvider) -> SwitcherCoordinator {
        SwitcherCoordinator(source: source, activator: FakeActivator(), directory: directory,
                            providers: FakeProviderLookup([provider]), gate: gate, resolver: nil,
                            windowServer: { nil })
    }

    private func tab(_ window: UInt32, _ token: String, _ title: String, active: Bool = false,
                     url: String? = nil) -> TabSnapshot {
        TabSnapshot(windowKey: .cg(window), token: token, title: title,
                    url: url.flatMap(URL.init(string:)), isActive: active, isPrivate: false)
    }

    // MARK: - Reading a window's tabs

    func testTabsAreListedForTheWindowTheRowStandsFor() async {
        let provider = FakeTabProvider(bundleIDs: [chrome.bundleID])
        let coordinator = makeCoordinator(provider)
        directory.set(apps: [chrome])
        source.set([chromeWindow(11, "one")], for: chrome)
        provider.set(tabs: [tab(11, "a", "one", active: true), tab(11, "b", "two")])
        await coordinator.refresh(app: chrome)

        let row = try? XCTUnwrap(coordinator.entries.first { $0.app.key == chrome.key })
        guard let row else { return }
        guard let window = coordinator.scriptWindow(for: row) else { return XCTFail("no script window") }
        XCTAssertEqual(coordinator.tabs(in: window).map(\.title), ["one", "two"])
    }

    func testAWindowWithNoTabsHasNoDetail() async {
        let provider = FakeTabProvider(bundleIDs: [chrome.bundleID])
        let coordinator = makeCoordinator(provider)
        directory.set(apps: [notes])
        source.set([window(21, notes, title: "Scratch")], for: notes)
        await coordinator.refresh(app: notes)

        guard let row = coordinator.entries.first else { return XCTFail("no row") }
        XCTAssertNil(coordinator.scriptWindow(for: row))
    }

    // MARK: - Closing a tab in place

    func testCloseTabAsksTheProviderAndRereads() async {
        let provider = FakeAccessibilityProvider(bundleIDs: [notes.bundleID])
        let coordinator = makeCoordinator(provider)
        directory.set(apps: [notes])
        source.set([window(31, notes, title: "Scratch")], for: notes)
        provider.set(tabs: [tab(31, "0", "first", active: true), tab(31, "1", "second")])
        await coordinator.refresh(app: notes)

        guard let row = coordinator.entries.first(where: { $0.kind == .tab }),
              let window = coordinator.scriptWindow(for: row) else { return XCTFail("no tab row") }
        let target = coordinator.tabs(in: window)[1]
        let closed = await coordinator.closeTab(target)

        XCTAssertTrue(closed)
        XCTAssertEqual(provider.closed.map(\.token), ["1"])
        XCTAssertEqual(coordinator.tabs(in: window).map(\.title), ["first"])
    }

    func testCloseTabReportsFailureWithoutTouchingTheList() async {
        let provider = FakeAccessibilityProvider(bundleIDs: [notes.bundleID])
        let coordinator = makeCoordinator(provider)
        directory.set(apps: [notes])
        source.set([window(32, notes, title: "Scratch")], for: notes)
        provider.set(tabs: [tab(32, "0", "first", active: true), tab(32, "1", "second")])
        await coordinator.refresh(app: notes)
        provider.failClose(with: ScriptError.timedOut)

        guard let row = coordinator.entries.first(where: { $0.kind == .tab }),
              let window = coordinator.scriptWindow(for: row) else { return XCTFail("no tab row") }
        let closed = await coordinator.closeTab(coordinator.tabs(in: window)[1])

        XCTAssertFalse(closed)
        XCTAssertEqual(coordinator.tabs(in: window).count, 2)
    }

    func testCloseTabDoesNothingForAWindowRow() async {
        let provider = FakeAccessibilityProvider(bundleIDs: [notes.bundleID])
        let coordinator = makeCoordinator(provider)
        directory.set(apps: [notes])
        source.set([window(33, notes, title: "Scratch")], for: notes)
        await coordinator.refresh(app: notes)

        guard let row = coordinator.entries.first else { return XCTFail("no row") }
        let closed = await coordinator.closeTab(row)
        XCTAssertFalse(closed)
        XCTAssertTrue(provider.closed.isEmpty)
    }

    // MARK: - The Accessibility provider's contract with the coordinator

    /// A scan that completed and saw no tab strip is evidence: Finder hides
    /// its tab bar the moment a window drops to one tab, and the rows for the
    /// tabs it used to have must go.
    func testEmptyAccessibilityReadDropsTheTabRows() async {
        let provider = FakeAccessibilityProvider(bundleIDs: [notes.bundleID])
        let coordinator = makeCoordinator(provider)
        directory.set(apps: [notes])
        source.set([window(41, notes, title: "Scratch")], for: notes)
        provider.set(tabs: [tab(41, "0", "first", active: true), tab(41, "1", "second")])
        await coordinator.refresh(app: notes)
        XCTAssertEqual(coordinator.entries.filter { $0.kind == .tab }.count, 1)

        provider.set(tabs: [])
        await coordinator.refresh(app: notes)

        XCTAssertTrue(coordinator.entries.allSatisfy { $0.kind == .window })
        XCTAssertEqual(coordinator.entries.count, 1)
    }

    /// The same empty answer from a script provider says nothing: it may have
    /// been refused or aimed at a browser that is still starting (L5).
    func testEmptyScriptReadKeepsTheTabRows() async {
        let provider = FakeTabProvider(bundleIDs: [chrome.bundleID])
        let coordinator = makeCoordinator(provider)
        directory.set(apps: [chrome])
        source.set([chromeWindow(42, "one")], for: chrome)
        provider.set(tabs: [tab(42, "a", "one", active: true), tab(42, "b", "two")])
        await coordinator.refresh(app: chrome)
        guard let window = coordinator.entries.first.flatMap({ coordinator.scriptWindow(for: $0) }) else {
            return XCTFail("no script window")
        }

        provider.set(tabs: [])
        await coordinator.refresh(app: chrome)

        XCTAssertEqual(coordinator.tabs(in: window).count, 2)
    }

    /// Accessibility needs no Automation consent, and putting a non-browser
    /// through that gate would ask the user to authorise Apple Events for an
    /// app nothing ever scripts.
    func testAccessibilityReadsSkipTheAutomationGate() async {
        let provider = FakeAccessibilityProvider(bundleIDs: [notes.bundleID])
        let coordinator = makeCoordinator(provider)
        directory.set(apps: [notes])
        source.set([window(43, notes, title: "Scratch")], for: notes)
        provider.set(tabs: [tab(43, "0", "first", active: true), tab(43, "1", "second")])

        gate.allowed = false
        await coordinator.refresh(app: notes)

        XCTAssertEqual(gate.checks, 0)
        XCTAssertEqual(coordinator.entries.filter { $0.kind == .tab }.count, 1)
    }

    // MARK: - Layout

    func testDetailHeightGrowsByOnePitchPerRow() {
        let one = DetailMetrics.height(rowCount: 1, visibleHeight: nil)
        let three = DetailMetrics.height(rowCount: 3, visibleHeight: nil)
        XCTAssertEqual(three - one, 2 * DetailMetrics.rowPitch, accuracy: 0.001)
    }

    func testDetailHeightNeverCollapsesBelowOneRow() {
        XCTAssertEqual(DetailMetrics.height(rowCount: 0, visibleHeight: nil),
                       DetailMetrics.height(rowCount: 1, visibleHeight: nil), accuracy: 0.001)
        // A screen too short for even one row still gets one row's height.
        XCTAssertEqual(DetailMetrics.height(rowCount: 40, visibleHeight: 100),
                       DetailMetrics.height(rowCount: 1, visibleHeight: nil), accuracy: 0.001)
    }

    /// ui-spec.md §3: the detail row wraps to two lines while the main list
    /// truncates to one. The two must not drift together.
    func testDetailAndMainListKeepTheirDifferences() {
        XCTAssertEqual(DetailMetrics.titleLineLimit, 2)
        XCTAssertNotEqual(DetailMetrics.rowPitch, Theme.rowPitch)
        XCTAssertNotEqual(DetailMetrics.faviconSize, Theme.iconSize)
    }

    // MARK: - Building the pane

    func testPaneNamesTheAppInItsPlaceholder() {
        let pane = DetailPane.make(app: chrome, appIcon: nil, tabs: [], matches: [:],
                                   isFiltered: false, favicon: { _ in nil })
        XCTAssertEqual(pane.searchPlaceholder, "Search tabs in Google Chrome")
    }

    /// A favicon that could not be found leaves the row's own image nil; the
    /// view then draws the app icon rather than empty space.
    func testRowsKeepAMissingFaviconNil() {
        let entries = [entry(token: "0", title: "one"), entry(token: "1", title: "two")]
        let rows = DetailPane.rows(for: entries, matches: [:], favicon: { _ in nil })
        XCTAssertEqual(rows.count, 2)
        XCTAssertTrue(rows.allSatisfy { $0.favicon == nil })
    }

    func testRowsCarryTheirMatchOffsets() {
        let one = entry(token: "0", title: "one")
        let rows = DetailPane.rows(for: [one], matches: [one.id: [0, 2]], favicon: { _ in nil })
        XCTAssertEqual(rows.first?.titleMatches, [0, 2])
    }

    private func entry(token: String, title: String) -> Entry {
        Entry(id: EntryID(key: .scripted(bundleID: chrome.bundleID, token: "1"), tabToken: token),
              kind: .tab, key: .scripted(bundleID: chrome.bundleID, token: "1"), app: chrome,
              title: title, discoveryRank: 0)
    }

    // MARK: - Panel transitions

    func testShowingAndHidingTheDetailPaneKeepsTheMainRows() {
        let model = PanelViewModel()
        let controller = PanelController(model: model)
        let mainRows = PanelViewModel.Row.placeholders(count: 5)
        controller.show(rows: mainRows, selectedIndex: 1)
        let mainHeight = controller.panel.frame.height

        let pane = DetailPane.make(app: chrome, appIcon: nil,
                                   tabs: [entry(token: "0", title: "one"), entry(token: "1", title: "two")],
                                   matches: [:], isFiltered: false, favicon: { _ in nil })
        controller.showDetail(pane, selectedIndex: 1)
        // Force a layout pass so a pane that cannot build its view fails here.
        controller.panel.contentView?.layoutSubtreeIfNeeded()
        controller.panel.displayIfNeeded()
        XCTAssertNotNil(model.detail)
        XCTAssertEqual(model.selectedIndex, 1)
        XCTAssertEqual(controller.panel.frame.height,
                       DetailMetrics.height(rowCount: 2, visibleHeight: controller.panel.screen?.visibleFrame.height),
                       accuracy: 0.001)
        // The panel grows and shrinks from the bottom; the top edge is fixed.
        let top = controller.panel.frame.maxY

        controller.hideDetail(rows: mainRows, selectedIndex: 1)
        XCTAssertNil(model.detail)
        XCTAssertEqual(model.rows.count, 5)
        XCTAssertEqual(model.selectedIndex, 1)
        XCTAssertEqual(controller.panel.frame.height, mainHeight, accuracy: 0.001)
        XCTAssertEqual(controller.panel.frame.maxY, top, accuracy: 0.001)
        controller.hide()
    }

    func testHidingThePanelTakesTheDetailPaneWithIt() {
        let model = PanelViewModel()
        let controller = PanelController(model: model)
        controller.show(rows: PanelViewModel.Row.placeholders(count: 2), selectedIndex: 0)
        controller.showDetail(DetailPane.make(app: chrome, appIcon: nil, tabs: [], matches: [:],
                                              isFiltered: false, favicon: { _ in nil }),
                              selectedIndex: 0)
        controller.hide()
        XCTAssertNil(model.detail)
    }

    // MARK: - The close chord

    func testOnlyPlainCommandWIsTheCloseChord() {
        XCTAssertTrue(DetailKeyMonitor.isCloseChord(key("w", .command)))
        XCTAssertFalse(DetailKeyMonitor.isCloseChord(key("w", [.command, .shift])))
        XCTAssertFalse(DetailKeyMonitor.isCloseChord(key("w", [])))
        XCTAssertFalse(DetailKeyMonitor.isCloseChord(key("q", .command)))
    }

    private func key(_ character: String, _ flags: NSEvent.ModifierFlags) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                         windowNumber: 0, context: nil, characters: character,
                         charactersIgnoringModifiers: character, isARepeat: false, keyCode: 13)!
    }
}
