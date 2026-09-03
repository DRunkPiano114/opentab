import XCTest
@testable import OpenTabCore

final class PinyinTests: XCTestCase {
    private func readings(_ character: Character) -> [String] {
        Pinyin.readings(of: character.unicodeScalars.first!)
    }

    func testCommonCharactersHaveTheirSingleReading() {
        XCTAssertEqual(readings("硕"), ["shuo"])
        XCTAssertEqual(readings("士"), ["shi"])
        XCTAssertEqual(readings("论"), ["lun"])
        XCTAssertEqual(readings("文"), ["wen"])
        XCTAssertEqual(readings("你"), ["ni"])
        XCTAssertEqual(readings("好"), ["hao"])
    }

    func testPolyphonesListEveryCommonReadingMostCommonFirst() {
        XCTAssertEqual(readings("重").first, "zhong")
        XCTAssertTrue(readings("重").contains("chong"))
        XCTAssertEqual(readings("长").first, "chang")
        XCTAssertTrue(readings("长").contains("zhang"))
        XCTAssertEqual(readings("行").first, "xing")
        XCTAssertTrue(readings("行").contains("hang"))
        XCTAssertEqual(readings("乐").first, "le")
        XCTAssertTrue(readings("乐").contains("yue"))
        XCTAssertEqual(readings("着").prefix(3).sorted(), ["zhao", "zhe", "zhuo"])
    }

    func testUmlautSyllablesAreSpelledBothWaysWithVFirst() {
        XCTAssertEqual(readings("女").prefix(2).map { $0 }, ["nv", "nu"])
        XCTAssertEqual(readings("略").prefix(2).map { $0 }, ["lve", "lue"])
        XCTAssertEqual(readings("率").first, "lv")
        XCTAssertTrue(readings("率").contains("lu"))
    }

    func testNonHanScalarsAreAbsent() {
        XCTAssertEqual(Pinyin.readings(of: "a"), [])
        XCTAssertEqual(Pinyin.readings(of: "é"), [])
        XCTAssertEqual(Pinyin.readings(of: "あ"), [])
        XCTAssertEqual(Pinyin.readings(of: Unicode.Scalar(0x4DFF)!), [])
        XCTAssertEqual(Pinyin.readings(of: Unicode.Scalar(0xA000)!), [])
    }

    func testExtremeScalarsDoNotCrash() {
        XCTAssertEqual(Pinyin.readings(of: Unicode.Scalar(0)!), [])
        XCTAssertEqual(Pinyin.readings(of: Unicode.Scalar(0x10FFFF)!), [])
    }

    func testCoverageAndReadingShape() {
        var covered = 0
        for value in UInt32(0x4E00)...UInt32(0x9FFF) {
            let result = Pinyin.readings(of: Unicode.Scalar(value)!)
            if result.isEmpty { continue }
            covered += 1
            XCTAssertEqual(Set(result).count, result.count, "duplicate reading at U+\(String(value, radix: 16))")
            for reading in result {
                XCTAssertFalse(reading.isEmpty)
                XCTAssertLessThanOrEqual(reading.count, 6, "\(reading) is too long")
                XCTAssertTrue(
                    reading.utf8.allSatisfy { $0 >= UInt8(ascii: "a") && $0 <= UInt8(ascii: "z") },
                    "\(reading) is not lowercase ASCII"
                )
            }
        }
        XCTAssertGreaterThanOrEqual(covered, 20000)
    }

    func testDecodingTheTableIsFastEnoughForStartup() {
        let start = DispatchTime.now().uptimeNanoseconds
        let table = PinyinTable.decode()
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
        print("PinyinTable decode: \(elapsed) ms")
        XCTAssertEqual(table.offsets.count, 0x9FFF - 0x4E00 + 2)
        XCTAssertEqual(Int(table.offsets.last!), table.ids.count)
        XCTAssertLessThan(elapsed, 100)
    }

    func testLookupThroughput() {
        _ = Pinyin.readings(of: "硕")
        var generator = SystemRandomNumberGenerator()
        let scalars = (0..<100_000).map { _ in
            Unicode.Scalar(UInt32.random(in: 0x4E00...0x9FFF, using: &generator))!
        }
        let start = DispatchTime.now().uptimeNanoseconds
        var total = 0
        for scalar in scalars { total += Pinyin.readings(of: scalar).count }
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
        print("PinyinTable 100k lookups: \(elapsed) ms, \(elapsed * 10) ns/op, \(total) readings")
        XCTAssertGreaterThan(total, 0)
        XCTAssertLessThan(elapsed, 200)
    }
}
