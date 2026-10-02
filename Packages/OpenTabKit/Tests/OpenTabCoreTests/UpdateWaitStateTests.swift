import XCTest
@testable import OpenTabCore

final class UpdateWaitStateTests: XCTestCase {
    private func state(_ events: UpdateWaitState.Event...) -> UpdateWaitState {
        var state = UpdateWaitState()
        for event in events { state.apply(event) }
        return state
    }

    private let backgroundFind = UpdateWaitState.Event.found(version: "0.4.0", shownByUpdater: false,
                                                             userInitiated: false)

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
        XCTAssertNil(state(.found(version: "0.4.0", shownByUpdater: true, userInitiated: false)).waiting)
    }

    func testAFindFromAUserCheckDoesNotWait() {
        XCTAssertNil(state(.found(version: "0.4.0", shownByUpdater: false, userInitiated: true)).waiting)
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

    /// The two waits come from different updater callbacks, and ending one
    /// must not erase the other.
    func testEachWaitEndsOnlyByItsOwnEvent() {
        let both = state(backgroundFind, .held(version: "0.4.1"))
        XCTAssertEqual(state(backgroundFind, .held(version: "0.4.1"), .cycleEnded).waiting, both.waiting)
        XCTAssertEqual(state(backgroundFind, .held(version: "0.4.1"), .sessionFinished).readyToInstall, "0.4.1")
    }
}
