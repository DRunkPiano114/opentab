import XCTest
@testable import OpenTabWS

final class ElementScannerTests: XCTestCase {
    private let far = ContinuousClock.now + .seconds(60)

    /// `windows`: element id → the window id `_AXUIElementGetWindow` would
    /// answer. `windowRoles`: the element ids whose role is `AXWindow`.
    private func probe(_ windows: [UInt64: UInt32], windowRoles: Set<UInt64>,
                       counter: Counter? = nil) -> ElementScanner.Probe {
        ElementScanner.Probe(windowID: { id in counter?.bump(); return windows[id] },
                             isWindow: { windowRoles.contains($0) })
    }

    final class Counter { var probes = 0; func bump() { probes += 1 } }

    private func scanner(maxID: UInt64 = 100, retry: Duration = .seconds(60)) -> ElementScanner {
        var scanner = ElementScanner()
        scanner.configuration.maxElementID = maxID
        scanner.configuration.budget = .seconds(10)
        scanner.configuration.exhaustedRetry = retry
        return scanner
    }

    func testFindsWantedWindowsAndStopsWhenAllFound() {
        var state = ElementScanner.State()
        let counter = Counter()
        let outcome = scanner().scan(wanted: [10, 20], state: &state, deadline: far,
                                     probe: probe([3: 10, 7: 20, 9: 30], windowRoles: [3, 7, 9], counter: counter))
        XCTAssertEqual(outcome.found, [10: 3, 20: 7])
        XCTAssertEqual(outcome.stop, .allFound)
        XCTAssertEqual(counter.probes, 8, "must stop right after the last hit")
        XCTAssertEqual(state.hits, [3, 7])
        XCTAssertEqual(state.cursor, 8)
    }

    /// A tab group or button answers the containing window's id; only an
    /// element whose role is AXWindow is a hit.
    func testRoleGateSkipsDescendants() {
        var state = ElementScanner.State()
        let outcome = scanner().scan(wanted: [10], state: &state, deadline: far,
                                     probe: probe([2: 10, 5: 10], windowRoles: [5]))
        XCTAssertEqual(outcome.found, [10: 5])
    }

    func testExpiredDeadlineProbesNothingAndKeepsWindowPending() {
        var state = ElementScanner.State()
        let counter = Counter()
        let scanner = scanner()
        let first = scanner.scan(wanted: [10], state: &state, deadline: .now - .seconds(1),
                                 probe: probe([4: 10], windowRoles: [4], counter: counter))
        XCTAssertEqual(first.stop, .budget)
        XCTAssertEqual(counter.probes, 0)
        let second = scanner.scan(wanted: [10], state: &state, deadline: far,
                                  probe: probe([4: 10], windowRoles: [4], counter: counter))
        XCTAssertEqual(second.found, [10: 4])
        XCTAssertEqual(state.pendingSince[10], nil)
    }

    func testWindowIsExhaustedAfterOneFullCycleAndRetriedLater() {
        var state = ElementScanner.State()
        let counter = Counter()
        let scanner = scanner(maxID: 10)
        let start = ContinuousClock.now
        let first = scanner.scan(wanted: [99], state: &state, deadline: far, now: start,
                                 probe: probe([:], windowRoles: [], counter: counter))
        XCTAssertEqual(first.stop, .exhausted)
        XCTAssertEqual(first.exhausted, [99])
        XCTAssertEqual(counter.probes, 10)
        XCTAssertNotNil(state.exhaustedAt[99])

        let second = scanner.scan(wanted: [99], state: &state, deadline: far, now: start + .seconds(1),
                                  probe: probe([:], windowRoles: [], counter: counter))
        XCTAssertEqual(second.stop, .nothingWanted)
        XCTAssertEqual(counter.probes, 10, "an exhausted window is not scanned for again inside the retry window")

        let third = scanner.scan(wanted: [99], state: &state, deadline: far, now: start + .seconds(61),
                                 probe: probe([3: 99], windowRoles: [3], counter: counter))
        XCTAssertEqual(third.found, [99: 3])
    }

    func testExhaustionOfOneWindowDoesNotHideAnotherHit() {
        var state = ElementScanner.State()
        let outcome = scanner(maxID: 20).scan(wanted: [1, 99], state: &state, deadline: far,
                                              probe: probe([15: 1], windowRoles: [15]))
        XCTAssertEqual(outcome.found, [1: 15])
        XCTAssertEqual(outcome.exhausted, [99])
        XCTAssertEqual(outcome.stop, .exhausted)
    }

    /// A still-pending window resumes at the cursor and wraps, so an id below
    /// where the last call stopped is still reached within one lap (H18).
    func testCursorResumesAcrossCallsAndWraps() {
        var state = ElementScanner.State()
        let scanner = scanner(maxID: 10)
        _ = scanner.scan(wanted: [2], state: &state, deadline: .now - .seconds(1), probe: probe([:], windowRoles: []))
        state.cursor = 7
        let counter = Counter()
        let outcome = scanner.scan(wanted: [2], state: &state, deadline: far,
                                   probe: probe([4: 2], windowRoles: [4], counter: counter))
        XCTAssertEqual(outcome.found, [2: 4])
        XCTAssertEqual(counter.probes, 8, "ids 7,8,9 then 0..4")
    }

    /// A window that just became wanted has a low id with high probability;
    /// the sweep restarts at 0 for it rather than finishing the current lap.
    func testNewlyWantedWindowRestartsTheSweepAtZero() {
        var state = ElementScanner.State()
        let scanner = scanner(maxID: 1_000)
        _ = scanner.scan(wanted: [1], state: &state, deadline: far, probe: probe([700: 1], windowRoles: [700]))
        XCTAssertEqual(state.cursor, 701)
        let counter = Counter()
        let outcome = scanner.scan(wanted: [2], state: &state, deadline: far,
                                   probe: probe([2: 2], windowRoles: [2], counter: counter))
        XCTAssertEqual(outcome.found, [2: 2])
        XCTAssertEqual(counter.probes, 3, "ids 0, 1, 2")
    }

    /// The restart is for new windows only: a window still pending from the
    /// last call keeps the cursor where it was, or the lap never completes.
    func testStillPendingWindowContinuesFromTheCursor() {
        var state = ElementScanner.State()
        let scanner = scanner(maxID: 1_000)
        var budgetScanner = scanner
        budgetScanner.configuration.budget = .zero
        _ = budgetScanner.scan(wanted: [1], state: &state, deadline: far, probe: probe([:], windowRoles: []))
        state.cursor = 500
        let counter = Counter()
        let outcome = scanner.scan(wanted: [1], state: &state, deadline: far,
                                   probe: probe([503: 1], windowRoles: [503], counter: counter))
        XCTAssertEqual(outcome.found, [1: 503])
        XCTAssertEqual(counter.probes, 4, "ids 500..503")
    }

    /// The restart also restarts every pending window's lap: a window that
    /// had probes counted before the reset is not exhausted until a whole
    /// lap after it, so an id above the reset point is still reached.
    func testRestartResetsExhaustionCountOfPendingWindows() {
        var state = ElementScanner.State()
        state.pendingSince[1] = 0
        state.totalProbed = 8
        state.cursor = 8
        let counter = Counter()
        let outcome = scanner(maxID: 10).scan(wanted: [1, 2], state: &state, deadline: far,
                                              probe: probe([8: 1], windowRoles: [8], counter: counter))
        XCTAssertEqual(outcome.found, [1: 8])
        XCTAssertFalse(outcome.exhausted.contains(1))
        XCTAssertEqual(counter.probes, 10, "ids 0..9: window 1 at 8, window 2 exhausted after the full lap")
        XCTAssertEqual(outcome.exhausted, [2])
    }

    func testPendingWindowsThatAreNoLongerWantedAreForgotten() {
        var state = ElementScanner.State()
        let scanner = scanner(maxID: 10)
        _ = scanner.scan(wanted: [5], state: &state, deadline: .now - .seconds(1), probe: probe([:], windowRoles: []))
        XCTAssertNotNil(state.pendingSince[5])
        _ = scanner.scan(wanted: [], state: &state, deadline: far, probe: probe([:], windowRoles: []))
        XCTAssertNil(state.pendingSince[5])
    }
}
