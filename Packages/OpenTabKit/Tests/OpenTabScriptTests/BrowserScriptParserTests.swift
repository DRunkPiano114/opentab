import XCTest
@testable import OpenTabScript

final class BrowserScriptParserTests: XCTestCase {
    private func window(_ fields: [ScriptValue]) -> ScriptValue { .list(fields) }
    private func strings(_ values: [String]) -> ScriptValue { .list(values.map { .text($0) }) }

    func testSafariRowsCarryIndicesTitlesAndURLs() {
        let value = ScriptValue.list([
            window([.text("36879"), .text("2"),
                    strings(["1", "2", "3"]),
                    strings(["Example Domain", "Apple", ""]),
                    strings(["https://example.com/", "https://www.apple.com/", "favorites://"])]),
        ])
        let rows = BrowserScriptParser.safariWindows(value)
        XCTAssertEqual(rows, [SafariWindowRow(windowID: "36879",
                                              activeTabIndex: 2,
                                              tabIndices: [1, 2, 3],
                                              titles: ["Example Domain", "Apple", ""],
                                              urls: ["https://example.com/", "https://www.apple.com/", "favorites://"])])
    }

    func testSafariWindowWithNoTabsIsKept() {
        let value = ScriptValue.list([
            window([.text("1"), .text("0"), .list([]), .list([]), .list([])]),
        ])
        XCTAssertEqual(BrowserScriptParser.safariWindows(value).first?.tabIndices, [])
    }

    func testMismatchedListsDropOnlyThatWindow() {
        let value = ScriptValue.list([
            window([.text("1"), .text("1"), strings(["1", "2"]), strings(["a"]), strings(["u", "v"])]),
            window([.text("2"), .text("1"), strings(["1"]), strings(["b"]), strings(["w"])]),
        ])
        XCTAssertEqual(BrowserScriptParser.safariWindows(value).map(\.windowID), ["2"])
    }

    func testMalformedTopLevelYieldsNothing() {
        XCTAssertTrue(BrowserScriptParser.safariWindows(.text("not a list")).isEmpty)
        XCTAssertTrue(BrowserScriptParser.chromiumWindows(.empty).isEmpty)
        XCTAssertTrue(BrowserScriptParser.safariWindows(.list([.text("bare")])).isEmpty)
    }

    func testChromiumRowsCarryModeAndTabIDs() {
        let value = ScriptValue.list([
            window([.text("1391121581"), .text("normal"), .text("12"),
                    strings(["1391122136", "1391122140"]),
                    strings(["Docs", "Mail"]),
                    strings(["https://docs.example/", "https://mail.example/"])]),
            window([.text("1391121538"), .text("incognito"), .text("1"),
                    strings(["9"]), strings(["Secret"]), strings(["https://private.example/"])]),
        ])
        let rows = BrowserScriptParser.chromiumWindows(value)
        XCTAssertEqual(rows.map(\.mode), ["normal", "incognito"])
        XCTAssertEqual(rows.first?.tabIDs, ["1391122136", "1391122140"])
        XCTAssertEqual(rows.first?.activeTabIndex, 12)
    }
}
