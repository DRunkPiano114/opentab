import XCTest
@testable import OpenTabScript

final class ScriptValueTests: XCTestCase {
    func testConvertsNestedListsAndCoercesScalarsToText() {
        let list = NSAppleEventDescriptor.list()
        list.insert(NSAppleEventDescriptor(int32: 36879), at: 0)
        let titles = NSAppleEventDescriptor.list()
        titles.insert(NSAppleEventDescriptor(string: "Example Domain"), at: 0)
        list.insert(titles, at: 0)

        let value = ScriptValue(descriptor: list)
        XCTAssertEqual(value, .list([.text("36879"), .list([.text("Example Domain")])]))
        XCTAssertEqual(value.items?.first?.integer, 36879)
    }

    func testEmptyListStaysAList() {
        XCTAssertEqual(ScriptValue(descriptor: .list()), .list([]))
    }

    func testNullDescriptorIsEmpty() {
        XCTAssertEqual(ScriptValue(descriptor: .null()), .empty)
        XCTAssertNil(ScriptValue.empty.string)
        XCTAssertNil(ScriptValue.empty.items)
    }

    func testBooleanArrivesAsText() {
        XCTAssertEqual(ScriptValue(descriptor: NSAppleEventDescriptor(boolean: false)).string?.lowercased(),
                       "false")
    }

    func testLargePayloadSurvivesConversion() {
        // The in-process path has no pipe to deadlock on; this just proves the
        // descriptor conversion is not size limited.
        let big = String(repeating: "x", count: 200_000)
        let value = ScriptValue(descriptor: NSAppleEventDescriptor(string: big))
        XCTAssertEqual(value.string?.count, big.count)
    }
}
