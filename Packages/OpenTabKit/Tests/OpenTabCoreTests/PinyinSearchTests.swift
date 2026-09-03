import XCTest
@testable import OpenTabCore

/// The six cases from reference/search.md §3, plus the properties that keep
/// the Chinese path from taxing English text.
final class PinyinSearchTests: XCTestCase {
    private let thesis = "硕士论文.pdf"

    func testHanQueryMatchesDirectly() {
        let m = FuzzyMatch.match(query: "硕士", candidate: thesis)
        XCTAssertEqual(m?.matchedIndices, [0, 1])
    }

    func testFullPinyinMatches() {
        let m = FuzzyMatch.match(query: "shuoshi", candidate: thesis)
        XCTAssertEqual(m?.matchedIndices, [0, 1])
    }

    func testInitialsMatch() {
        let m = FuzzyMatch.match(query: "ss", candidate: thesis)
        XCTAssertEqual(m?.matchedIndices, [0, 1])
    }

    func testMixedInitialsAndLatin() {
        let m = FuzzyMatch.match(query: "ss report", candidate: "硕士 report")
        XCTAssertEqual(m?.matchedIndices, [0, 1, 2, 3, 4, 5, 6, 7, 8])
    }

    func testContinuousFullPinyinMatches() {
        let m = FuzzyMatch.match(query: "shuoshilunwen", candidate: thesis)
        XCTAssertEqual(m?.matchedIndices, [0, 1, 2, 3])
    }

    func testEveryReadingOfAPolyphoneMatches() {
        XCTAssertNotNil(FuzzyMatch.match(query: "zhong", candidate: "重要通知"))
        XCTAssertNotNil(FuzzyMatch.match(query: "chong", candidate: "重要通知"))
        XCTAssertNotNil(FuzzyMatch.match(query: "cf", candidate: "重复"))
    }

    func testPartialSyllableWhileTyping() {
        for prefix in ["s", "sh", "shu", "shuo", "shuos", "shuosh", "shuoshi", "shuoshil"] {
            XCTAssertNotNil(FuzzyMatch.match(query: prefix, candidate: thesis), prefix)
        }
    }

    func testWrongSyllableDoesNotMatch() {
        XCTAssertNil(FuzzyMatch.match(query: "shua", candidate: thesis))
        XCTAssertNil(FuzzyMatch.match(query: "xyz", candidate: thesis))
    }

    func testHanQueryOnlyMatchesTheSameCharacter() {
        XCTAssertNil(FuzzyMatch.match(query: "硕", candidate: "shuo.txt"))
        XCTAssertNil(FuzzyMatch.match(query: "论", candidate: "硕士"))
    }

    func testDirectLatinOutranksPinyin() {
        XCTAssertEqual(FuzzyMatch.rank(query: "shuoshi", candidates: [thesis, "shuoshi.txt"]).first?.candidate, "shuoshi.txt")
        XCTAssertEqual(FuzzyMatch.rank(query: "ss", candidates: [thesis, "System Settings"]).first?.candidate, "System Settings")
    }

    func testFullSyllableOutranksInitials() {
        let full = FuzzyMatch.match(query: "shuoshi", candidate: thesis)!.score
        let initials = FuzzyMatch.match(query: "ss", candidate: thesis)!.score
        XCTAssertGreaterThan(full, initials)
    }

    func testAdjacentCharactersOutrankScattered() {
        XCTAssertEqual(FuzzyMatch.rank(query: "ss", candidates: ["硕大的士兵", "硕士"]).first?.candidate, "硕士")
    }

    func testFullwidthAndCaseFoldStillApplyToLatin() {
        XCTAssertNotNil(FuzzyMatch.match(query: "abc", candidate: "ＡＢＣ 文档"))
    }

    func testASCIITextBuildsNoPinyinIndex() {
        let text = IndexedText("Google Chrome — GitHub: opentab/opentab")
        XCTAssertFalse(text.hasPinyin)
        XCTAssertTrue(text.pinyin.isEmpty)
    }

    func testHanTextIndexesReadingsOnlyAtHanOffsets() {
        let text = IndexedText("a硕b")
        XCTAssertTrue(text.hasPinyin)
        XCTAssertEqual(text.pinyin.map(\.count), [0, 1, 0])
    }

    func testIndexBuildIsFast() {
        let title = "硕士学历彻底沦为废纸！不要盲目读硕士，更不要寄托于读硕士来改变命运！ - YouTube - Google Chrome"
        _ = IndexedText(title)
        let rounds = 200
        let start = ContinuousClock.now
        for _ in 0..<rounds { _ = IndexedText(title) }
        let perBuild = start.duration(to: .now) / rounds
        print("IndexedText build: \(perBuild) for \(title.count) chars")
        XCTAssertLessThan(perBuild, .microseconds(200), "budget is 50us in release; debug allowance is 4x")
    }

    func testChineseMatchCostIsSameOrderAsEnglish() {
        let cjk = IndexedText(String(repeating: "硕士学历彻底沦为废纸不要盲目读硕士更不要寄托于读", count: 2))
        let ascii = IndexedText(String(repeating: "Enterprise Sales Startup School YouTube Google ", count: 2))
        let queryCJK = FuzzyMatch.Query("ss")
        let queryASCII = FuzzyMatch.Query("ss")
        let rounds = 2000
        var scratch = FuzzyMatch.Scratch()
        var start = ContinuousClock.now
        for _ in 0..<rounds { _ = FuzzyMatch.match(queryCJK, in: cjk, scratch: &scratch) }
        let cjkTime = start.duration(to: .now)
        start = .now
        for _ in 0..<rounds { _ = FuzzyMatch.match(queryASCII, in: ascii, scratch: &scratch) }
        let asciiTime = start.duration(to: .now)
        print("match x\(rounds): cjk=\(cjkTime) ascii=\(asciiTime) (\(cjk.count) vs \(ascii.count) chars)")
        XCTAssertLessThan(cjkTime, asciiTime * 4)
    }
}
