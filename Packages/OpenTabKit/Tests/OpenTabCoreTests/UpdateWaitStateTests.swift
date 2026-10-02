import XCTest
@testable import OpenTabCore

final class UpdateWaitStateTests: XCTestCase {
    private func state(_ events: UpdateWaitState.Event...) -> UpdateWaitState {
        var state = UpdateWaitState()
        for event in events { state.apply(event) }
        return state
    }

    private static let foundDate = Date(timeIntervalSinceReferenceDate: 800_000_000)
    /// Three days of wall-clock time.
    private static let limit: TimeInterval = 259_200

    private let backgroundFind = UpdateWaitState.Event.found(version: "0.4.0", shownByUpdater: false,
                                                             userInitiated: false, date: UpdateWaitStateTests.foundDate)

    private func later(_ interval: TimeInterval) -> Date {
        Self.foundDate.addingTimeInterval(interval)
    }

    func testTheMenuCarriesOnlyANonCriticalUpdateWhileTheIconIsShown() {
        XCTAssertTrue(UpdateWaitState.menuCarries(statusItemVisible: true, isCritical: false))
        XCTAssertFalse(UpdateWaitState.menuCarries(statusItemVisible: false, isCritical: false),
                       "with the icon hidden there is no menu to carry it")
        XCTAssertFalse(UpdateWaitState.menuCarries(statusItemVisible: true, isCritical: true),
                       "a critical update must not wait for the menu to be opened")
        XCTAssertFalse(UpdateWaitState.menuCarries(statusItemVisible: false, isCritical: true))
    }

    func testABackgroundFindWaitsUnseen() {
        XCTAssertEqual(state(backgroundFind).waiting, StatusMenuSpec.WaitingUpdate(version: "0.4.0"))
    }

    func testAFindTheUpdaterShowsItselfDoesNotWait() {
        XCTAssertNil(state(.found(version: "0.4.0", shownByUpdater: true, userInitiated: false, date: Self.foundDate)).waiting)
    }

    func testAFindFromAUserCheckDoesNotWait() {
        XCTAssertNil(state(.found(version: "0.4.0", shownByUpdater: false, userInitiated: true, date: Self.foundDate)).waiting)
    }

    func testSeeingTheUpdateKeepsItWaiting() {
        XCTAssertEqual(state(backgroundFind, .seen).waiting, StatusMenuSpec.WaitingUpdate(version: "0.4.0", seen: true))
    }

    func testEndingTheSessionClearsTheWaitingUpdate() {
        XCTAssertNil(state(backgroundFind, .seen, .sessionFinished).waiting)
        XCTAssertNil(state(backgroundFind, .sessionFinished).waiting)
    }

    func testSeenWithNothingWaitingInventsNothing() {
        XCTAssertEqual(state(.seen), UpdateWaitState())
    }

    func testAHeldUpdateIsReadyUntilItsCycleEnds() {
        XCTAssertEqual(state(.held(version: "0.4.1")).readyToInstall, "0.4.1")
        XCTAssertNil(state(.held(version: "0.4.1"), .cycleEnded).readyToInstall)
    }

    /// Either end event arrives from a different updater callback, and one of
    /// them going missing must not strand an item in the menu.
    func testEitherEndEventClearsEveryWait() {
        for end in [UpdateWaitState.Event.sessionFinished, .cycleEnded] {
            XCTAssertEqual(state(backgroundFind, .held(version: "0.4.1"), end), UpdateWaitState(), "\(end)")
            XCTAssertEqual(state(backgroundFind, .seen, end), UpdateWaitState(), "\(end)")
            XCTAssertEqual(state(.held(version: "0.4.1"), end), UpdateWaitState(), "\(end)")
        }
    }

    func testTheUpdaterShowsAFindExactlyWhenTheMenuDoesNotCarryIt() {
        XCTAssertFalse(UpdateWaitState.updaterShowsFind(statusItemVisible: true, isCritical: false))
        XCTAssertTrue(UpdateWaitState.updaterShowsFind(statusItemVisible: false, isCritical: false),
                      "with the icon hidden the updater's window is the only place to show it")
        XCTAssertTrue(UpdateWaitState.updaterShowsFind(statusItemVisible: true, isCritical: true),
                      "a critical update is shown at once")
        XCTAssertTrue(UpdateWaitState.updaterShowsFind(statusItemVisible: false, isCritical: true))
    }

    func testAFoundUpdateCanBeBroughtForwardSeenOrNot() {
        XCTAssertTrue(state(backgroundFind).canBringForward)
        XCTAssertTrue(state(backgroundFind, .seen).canBringForward)
    }

    func testNothingIsBroughtForwardWithoutAFoundUpdate() {
        XCTAssertFalse(UpdateWaitState().canBringForward)
        XCTAssertFalse(state(backgroundFind, .sessionFinished).canBringForward)
    }

    func testAHeldUpdateIsNeverBroughtForward() {
        XCTAssertFalse(state(.held(version: "0.4.1")).canBringForward)
        XCTAssertFalse(state(backgroundFind, .held(version: "0.4.1")).canBringForward,
                       "the updater has no window for an update held for install")
    }

    func testAnUnseenUpdateIsBroughtForwardAtTheLimitAndNotBefore() {
        XCTAssertFalse(state(backgroundFind).bringsForward(now: later(Self.limit - 1)))
        XCTAssertTrue(state(backgroundFind).bringsForward(now: later(Self.limit)))
        XCTAssertTrue(state(backgroundFind).bringsForward(now: later(Self.limit * 10)))
    }

    func testAnUpdateIsBroughtForwardOnlyOnce() {
        let brought = state(backgroundFind, .broughtForward)
        XCTAssertFalse(brought.bringsForward(now: later(Self.limit)))
        XCTAssertFalse(brought.bringsForward(now: later(Self.limit * 10)))
    }

    func testASeenUpdateIsNotBroughtForward() {
        XCTAssertFalse(state(backgroundFind, .seen).bringsForward(now: later(Self.limit)))
    }

    func testAHeldUpdateIsNotBroughtForwardByTheLimit() {
        XCTAssertFalse(state(backgroundFind, .held(version: "0.4.1")).bringsForward(now: later(Self.limit)))
        XCTAssertFalse(state(.held(version: "0.4.1")).bringsForward(now: later(Self.limit)))
    }

    func testNothingIsBroughtForwardWithNothingWaiting() {
        XCTAssertFalse(UpdateWaitState().bringsForward(now: later(Self.limit)))
        XCTAssertFalse(state(backgroundFind, .sessionFinished).bringsForward(now: later(Self.limit)))
        XCTAssertEqual(state(.broughtForward), UpdateWaitState(), "nothing is recorded for no update")
    }

    func testANewFindStartsItsOwnLimit() {
        let refound = UpdateWaitState.Event.found(version: "0.4.2", shownByUpdater: false,
                                                  userInitiated: false, date: later(Self.limit))
        XCTAssertFalse(state(backgroundFind, .broughtForward, refound).bringsForward(now: later(Self.limit * 2 - 1)))
        XCTAssertTrue(state(backgroundFind, .broughtForward, refound).bringsForward(now: later(Self.limit * 2)))
        XCTAssertTrue(state(backgroundFind, .broughtForward, .sessionFinished, refound)
            .bringsForward(now: later(Self.limit * 2)))
    }
}
