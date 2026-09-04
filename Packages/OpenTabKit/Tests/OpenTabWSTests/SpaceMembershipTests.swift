import XCTest
import OpenTabWS

/// The scene from a real dump: two displays, active Spaces {3, 829}; wid 82
/// on 1088 and the fullscreen Safari on 1109 are off; the minimized wid 122
/// has no Space at all.
final class SpaceMembershipTests: XCTestCase {
    private let active: Set<UInt64> = [3, 829]

    func testWindowOnAnyDisplaysCurrentSpaceIsActive() {
        XCTAssertTrue(SpaceMembership.isOnActiveSpace(windowSpaces: [3], activeSpaces: active, isMinimized: false))
        XCTAssertTrue(SpaceMembership.isOnActiveSpace(windowSpaces: [829], activeSpaces: active, isMinimized: false))
    }

    func testWindowOnBackgroundOrFullscreenSpaceIsNotActive() {
        XCTAssertFalse(SpaceMembership.isOnActiveSpace(windowSpaces: [1088], activeSpaces: active, isMinimized: false))
        XCTAssertFalse(SpaceMembership.isOnActiveSpace(windowSpaces: [1109], activeSpaces: active, isMinimized: false))
    }

    func testWindowSpanningSpacesCountsIfAnyIsActive() {
        XCTAssertTrue(SpaceMembership.isOnActiveSpace(windowSpaces: [1088, 829], activeSpaces: active, isMinimized: false))
    }

    /// No Space at all falls back to the minimized flag.
    func testEmptySpaceListFallsBackToMinimized() {
        XCTAssertTrue(SpaceMembership.isOnActiveSpace(windowSpaces: [], activeSpaces: active, isMinimized: true))
        XCTAssertFalse(SpaceMembership.isOnActiveSpace(windowSpaces: [], activeSpaces: active, isMinimized: false))
    }

    func testNoActiveSpacesKnownMeansNotActive() {
        XCTAssertFalse(SpaceMembership.isOnActiveSpace(windowSpaces: [3], activeSpaces: [], isMinimized: false))
    }
}
