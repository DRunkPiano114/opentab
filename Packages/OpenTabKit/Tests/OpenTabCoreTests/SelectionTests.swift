import XCTest
@testable import OpenTabCore

final class SelectionTests: XCTestCase {
    func testOpensOnSecondEntry() {
        XCTAssertEqual(Selection(count: 3).index, 1)
    }

    func testSingleEntryOpensOnItself() {
        XCTAssertEqual(Selection(count: 1).index, 0)
    }

    func testEmptyIsSafe() {
        var s = Selection(count: 0)
        s.advance(by: 5)
        XCTAssertEqual(s.index, 0)
        XCTAssertTrue(s.isEmpty)
    }

    func testAdvanceWraps() {
        var s = Selection(count: 3)
        s.advance(by: 2)
        XCTAssertEqual(s.index, 0)
        s.advance(by: -1)
        XCTAssertEqual(s.index, 2)
    }

    func testListChangeFollowsTheSelectedRow() {
        var s = Selection(count: 4)
        s.select(3)
        s.listChanged(count: 5, previousRowNowAt: 4)
        XCTAssertEqual(s.index, 4)
        s.listChanged(count: 2, previousRowNowAt: nil)
        XCTAssertEqual(s.index, 1)
    }
}
