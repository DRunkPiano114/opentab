import XCTest
@testable import OpenTabCore

/// The Latin baseline the matcher was ported from. Every case here guards a
/// ranking property; none may regress for the sake of Chinese support.
final class FuzzyMatchTests: XCTestCase {
    func rankOrder(_ q: String, _ cs: [String]) -> [String] {
        FuzzyMatch.rank(query: q, candidates: cs).map(\.candidate)
    }

    func testRejectsNonSubsequence() {
        XCTAssertNil(FuzzyMatch.match(query: "xyz", candidate: "Google Chrome"))
        XCTAssertNil(FuzzyMatch.match(query: "chrome!", candidate: "Chrome"))
    }

    func testEmptyQueryMatchesAll() {
        XCTAssertEqual(FuzzyMatch.match(query: "", candidate: "anything")?.score, 0)
    }

    func testCaseAndDiacriticInsensitive() {
        XCTAssertNotNil(FuzzyMatch.match(query: "CAFE", candidate: "Café Terminal"))
        XCTAssertNotNil(FuzzyMatch.match(query: "resume", candidate: "Résumé.pdf"))
    }

    func testMatchedIndicesAreCorrect() {
        let m = FuzzyMatch.match(query: "gc", candidate: "Google Chrome")!
        XCTAssertEqual(m.matchedIndices, [0, 7])
        let cand = Array("Google Chrome")
        XCTAssertEqual(m.matchedIndices.map { cand[$0] }, ["G", "C"])
    }

    func testIndicesAlwaysAscendingAndInBounds() {
        for (q, c) in [("gc", "Google Chrome"), ("dev", "Chrome DevTools"), ("mth", "my_test_helper.swift"), ("ii", "Inbox — iCloud")] {
            let m = FuzzyMatch.match(query: q, candidate: c)!
            XCTAssertEqual(m.matchedIndices.count, q.count, "\(q)/\(c)")
            XCTAssertEqual(m.matchedIndices, m.matchedIndices.sorted(), "\(q)/\(c)")
            XCTAssertTrue(m.matchedIndices.allSatisfy { $0 >= 0 && $0 < c.count }, "\(q)/\(c)")
        }
    }

    // --- ranking behaviour: the reason we score at all ---

    func testWordStartBeatsMidWord() {
        XCTAssertEqual(rankOrder("chr", ["Searchers", "Chrome"]).first, "Chrome")
    }

    func testAcronymOfWordStarts() {
        XCTAssertEqual(rankOrder("gc", ["Logic Pro", "Google Chrome"]).first, "Google Chrome")
    }

    func testCamelCaseBoundaryBeatsMidWordAtSamePosition() {
        XCTAssertEqual(rankOrder("dt", ["Chromedxxtxx", "ChromeDxxTxx"]).first, "ChromeDxxTxx")
    }

    func testCamelCaseAcronymIsFound() {
        XCTAssertNotNil(FuzzyMatch.match(query: "dt", candidate: "ChromeDevTools"))
        XCTAssertEqual(FuzzyMatch.match(query: "dt", candidate: "ChromeDevTools")!.matchedIndices, [6, 9])
    }

    func testUppercaseQueryPrefersMatchingCase() {
        XCTAssertEqual(rankOrder("DT", ["chromedxxtxx", "chromeDxxTxx"]).first, "chromeDxxTxx")
    }

    func testLowercaseQueryDoesNotFavourLowercaseCandidates() {
        XCTAssertEqual(rankOrder("ss", ["sublime scratch", "System Settings"]).first, "System Settings")
    }

    func testConsecutiveRunBeatsScattered() {
        let run = FuzzyMatch.match(query: "abc", candidate: "zabcz")!.score
        let scattered = FuzzyMatch.match(query: "abc", candidate: "zazbzcz")!.score
        XCTAssertGreaterThan(run, scattered)
    }

    func testShorterPrefixBeatsLongerPrefix() {
        XCTAssertEqual(rankOrder("term", ["iTerm2 — long window title here", "Terminal"]).first, "Terminal")
    }

    func testSeparatorBoundary() {
        XCTAssertEqual(rankOrder("mth", ["mathematics", "my_test_helper"]).first, "my_test_helper")
    }

    func testRealisticSwitcherRanking() {
        let rows = [
            "Slack — general",
            "Google Chrome — GitHub",
            "Terminal — ~/src",
            "Xcode — OpenTab.xcodeproj",
            "Safari — Chrome DevTools docs",
        ]
        XCTAssertEqual(rankOrder("chrome", rows).first, "Google Chrome — GitHub")
        XCTAssertEqual(rankOrder("xc", rows).first, "Xcode — OpenTab.xcodeproj")
    }

    func testPerformance1000Rows() {
        let rows = (0..<1000).map { "Application \($0) — some window title \($0)" }
        _ = FuzzyMatch.rank(query: "app", candidates: rows)
        let start = ContinuousClock.now
        _ = FuzzyMatch.rank(query: "app", candidates: rows)
        let elapsed = start.duration(to: .now)
        print("rank 1000 rows (index build included): \(elapsed)")
        XCTAssertLessThan(elapsed, .milliseconds(200))
    }
}
