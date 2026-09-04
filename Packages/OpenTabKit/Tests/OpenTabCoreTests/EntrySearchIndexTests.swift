import XCTest
@testable import OpenTabCore

final class EntrySearchIndexTests: XCTestCase {
    private var rank: UInt64 = 0

    private func entry(_ appName: String, _ title: String, kind: EntryKind = .window, url: String? = nil,
                       focusTick: UInt64 = 0, id: UInt32? = nil) -> Entry {
        rank += 1
        let key = WindowKey.cg(id ?? UInt32(rank))
        return Entry(id: EntryID(key: key, tabToken: kind == .tab ? "t\(rank)" : nil), kind: kind, key: key,
                     app: AppInfo(bundleID: "com.example.\(appName)", pid: 1, localizedName: appName),
                     title: title, url: url.flatMap(URL.init(string:)), focusTick: focusTick, discoveryRank: rank)
    }

    private func titles(_ hits: [SearchHit]) -> [String] { hits.map(\.entry.title) }

    func testEmptyQueryIsRecencyOrder() {
        var index = EntrySearchIndex()
        index.update(with: [entry("A", "old", focusTick: 1), entry("B", "newest", focusTick: 9), entry("C", "never")])
        XCTAssertEqual(titles(index.search("")), ["newest", "old", "never"])
        XCTAssertEqual(titles(index.search("  \t")), ["newest", "old", "never"])
    }

    func testNonMatchesAreDropped() {
        var index = EntrySearchIndex()
        index.update(with: [entry("Safari", "Docs"), entry("Xcode", "OpenTab")])
        XCTAssertEqual(titles(index.search("xc")), ["OpenTab"])
    }

    func testAppNameOutranksTitle() {
        var index = EntrySearchIndex()
        index.update(with: [entry("Safari", "Chrome DevTools docs", focusTick: 5),
                            entry("Google Chrome", "GitHub", focusTick: 1)])
        XCTAssertEqual(titles(index.search("chrome")), ["GitHub", "Chrome DevTools docs"])
    }

    func testTabTitleOutranksWindowTitle() {
        var index = EntrySearchIndex()
        index.update(with: [entry("App", "Release notes", kind: .window, focusTick: 5),
                            entry("App", "Release notes", kind: .tab, focusTick: 1)])
        XCTAssertEqual(index.search("release").map(\.entry.kind), [.tab, .window])
    }

    func testURLMatchesButRanksLast() {
        var index = EntrySearchIndex()
        index.update(with: [entry("Safari", "Home", url: "https://github.com/opentab", focusTick: 9),
                            entry("Safari", "GitHub issues", focusTick: 1)])
        XCTAssertEqual(titles(index.search("github")), ["GitHub issues", "Home"])
    }

    func testQuerySpansAppNameAndTitle() {
        var index = EntrySearchIndex()
        index.update(with: [entry("Google Chrome", "GitHub"), entry("Google Chrome", "YouTube")])
        XCTAssertEqual(titles(index.search("chrome github")), ["GitHub"])
    }

    func testEqualScoresFallBackToRecency() {
        var index = EntrySearchIndex()
        index.update(with: [entry("Terminal", "zsh", focusTick: 1), entry("Terminal", "zsh", focusTick: 7)])
        XCTAssertEqual(index.search("term").map(\.entry.focusTick), [7, 1])
    }

    func testHighlightsAddressTheRightField() {
        var index = EntrySearchIndex()
        index.update(with: [entry("Google Chrome", "GitHub")])
        let byApp = index.search("gc").first!
        XCTAssertEqual(byApp.appNameMatches, [0, 7])
        XCTAssertEqual(byApp.titleMatches, [])
        let byTitle = index.search("hub").first!
        XCTAssertEqual(byTitle.titleMatches, [3, 4, 5])
        let spanning = index.search("chromegit").first!
        XCTAssertEqual(spanning.appNameMatches, [7, 8, 9, 10, 11, 12])
        XCTAssertEqual(spanning.titleMatches, [0, 1, 2])
    }

    func testPinyinFindsChineseTitle() {
        var index = EntrySearchIndex()
        index.update(with: [entry("Google Chrome", "硕士论文.pdf"), entry("Google Chrome", "Enterprise Sales")])
        XCTAssertEqual(titles(index.search("shuoshi")), ["硕士论文.pdf"])
        XCTAssertEqual(titles(index.search("ss")).first, "硕士论文.pdf")
        XCTAssertEqual(index.search("ss").first?.titleMatches, [0, 1])
    }

    func testTitleChangeInvalidatesCachedIndex() {
        var index = EntrySearchIndex()
        let original = entry("Preview", "硕士论文.pdf", id: 42)
        index.update(with: [original])
        XCTAssertEqual(index.search("shuoshi").count, 1)

        var renamed = original
        renamed.title = "Budget.xlsx"
        index.update(with: [renamed])
        XCTAssertEqual(index.search("shuoshi").count, 0)
        XCTAssertEqual(titles(index.search("budget")), ["Budget.xlsx"])
    }

    func testRemovedEntriesLeaveTheIndex() {
        var index = EntrySearchIndex()
        let a = entry("A", "alpha"), b = entry("B", "beta")
        index.update(with: [a, b])
        index.update(with: [b])
        XCTAssertEqual(index.count, 1)
        XCTAssertEqual(index.search("alpha").count, 0)
    }

    func testMetadataRefreshKeepsIndexAndUpdatesEntry() {
        var index = EntrySearchIndex()
        let original = entry("A", "alpha", id: 7)
        index.update(with: [original])
        var bumped = original
        bumped.focusTick = 99
        index.update(with: [bumped])
        XCTAssertEqual(index.search("alpha").first?.entry.focusTick, 99)
    }

    func testTwoThousandRowsUnderBudget() {
        var index = EntrySearchIndex()
        var rows: [Entry] = []
        for i in 0..<2000 {
            let title = i % 5 == 0
                ? "硕士论文提纲第二稿：研究背景与方法 \(i) - YouTube"
                : "Quarterly Planning | Sample Session \(i) - YouTube"
            rows.append(entry(["Google Chrome", "Safari", "Xcode", "Terminal"][i % 4], title, focusTick: UInt64(i)))
        }
        let buildStart = ContinuousClock.now
        index.update(with: rows)
        let buildTime = buildStart.duration(to: .now)

        _ = index.search("ss")
        var timings: [(String, Duration)] = []
        for query in ["ss", "shuoshi", "youtube", "chrome", "xq"] {
            let start = ContinuousClock.now
            let hits = index.search(query)
            timings.append((query, start.duration(to: .now)))
            XCTAssertLessThanOrEqual(hits.count, 2000)
        }
        print("index build 2000 rows: \(buildTime); search: \(timings)")
        // The 10ms budget is a release figure (measured 2-6ms); unoptimised
        // builds run this DP roughly 20x slower, so debug only sanity-checks.
        #if DEBUG
        let budget: Duration = .milliseconds(400)
        #else
        let budget: Duration = .milliseconds(10)
        #endif
        for (query, time) in timings {
            XCTAssertLessThan(time, budget, query)
        }
    }
}
