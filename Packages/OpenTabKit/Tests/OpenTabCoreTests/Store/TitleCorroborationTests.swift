import XCTest
@testable import OpenTabCore

final class TitleCorroborationTests: XCTestCase {
    private func corroborates(_ window: String, _ tab: String, app: String? = "Google Chrome") -> Bool {
        TitleCorroboration.corroborates(windowTitle: window, tabTitle: tab, appName: app)
    }

    func testChromeSuffixIsStripped() {
        XCTAssertTrue(corroborates("GitHub - Google Chrome", "GitHub"))
        XCTAssertEqual(TitleCorroboration.normalize("GitHub - Google Chrome", appName: "Google Chrome"), "GitHub")
    }

    func testEqualityIsNotRequired() {
        XCTAssertFalse("GitHub - Google Chrome" == "GitHub", "the naive predicate never claims a Chrome window")
        XCTAssertTrue(corroborates("GitHub - Google Chrome", "GitHub"))
    }

    func testProfileSuffixFallsBackToPrefixRule() {
        XCTAssertTrue(corroborates("GitHub - Google Chrome - Paul", "GitHub"))
    }

    func testEmDashAndEnDashSeparators() {
        XCTAssertTrue(corroborates("Docs — Google Chrome", "Docs"))
        XCTAssertTrue(corroborates("Docs – Google Chrome", "Docs"))
    }

    func testUnreadCountIsStripped() {
        XCTAssertEqual(TitleCorroboration.normalize("Inbox (3)"), "Inbox")
        XCTAssertEqual(TitleCorroboration.normalize("Inbox(12) "), "Inbox")
        XCTAssertEqual(TitleCorroboration.normalize("f(x)"), "f(x)", "only a numeric count is a badge")
        XCTAssertTrue(corroborates("Inbox (3) - Google Chrome", "Inbox"))
    }

    func testUnicodeNFCAndWhitespaceCollapse() {
        let decomposed = "Cafe\u{0301}   menu"
        XCTAssertEqual(TitleCorroboration.normalize(decomposed), "Café menu")
        XCTAssertTrue(corroborates("  Café \n menu - Google Chrome", "Café menu"))
    }

    func testEmptyTitlesNeverCorroborate() {
        XCTAssertFalse(corroborates("", "GitHub"))
        XCTAssertFalse(corroborates("GitHub - Google Chrome", ""))
        XCTAssertFalse(corroborates(" - Google Chrome", "   "))
    }

    func testShortPrefixNeedsWordBoundary() {
        XCTAssertFalse(corroborates("GitHub - Google Chrome", "Git"))
        XCTAssertTrue(corroborates("Git - the docs - Google Chrome", "Git"))
        XCTAssertTrue(corroborates("新标签页 - Google Chrome", "新标签页"))
        XCTAssertFalse(corroborates("新标签页面板 - Google Chrome", "新标签页"))
    }

    func testLongPrefixMatchesTruncatedWindowTitle() {
        XCTAssertTrue(corroborates("Pull Request #42: reconcile the st", "Pull Request #42: reconcile the store", app: nil))
    }

    func testContainmentNeedsEightCharacters() {
        XCTAssertTrue(corroborates("[Draft] Quarterly report - Google Chrome", "Quarterly report"))
        XCTAssertFalse(corroborates("[Draft] Report - Google Chrome", "Report"))
    }
}
