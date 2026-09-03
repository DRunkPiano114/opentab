import XCTest
@testable import OpenTabScript

final class ScriptErrorTests: XCTestCase {
    func testMapsTheDocumentedCodes() {
        let cases: [(Int, ScriptError)] = [
            (-1712, .timedOut),
            (-1743, .notPermitted),
            (-10004, .notPermitted),
            (-1744, .permissionUndetermined),
            (-600, .targetNotRunning),
            (-609, .targetNotRunning),
            (-1719, .indexRace),
            (-1728, .indexRace),
        ]
        for (code, expected) in cases {
            XCTAssertEqual(ScriptError.mapExecution(code: code, message: ""), expected, "code \(code)")
        }
    }

    func testUnknownCodeKeepsItsNumber() {
        XCTAssertEqual(ScriptError.mapExecution(code: -1708, message: "nope"),
                       .failed(code: -1708, message: "nope"))
    }

    func testOnlySkippableCodesAreBenign() {
        XCTAssertTrue(ScriptError.targetNotRunning.isBenign)
        XCTAssertTrue(ScriptError.indexRace.isBenign)
        XCTAssertFalse(ScriptError.notPermitted.isBenign)
        XCTAssertFalse(ScriptError.timedOut.isBenign)
    }

    func testReadsAnNSAppleScriptErrorDictionary() {
        let info: NSDictionary = [
            NSAppleScript.errorNumber: -1743,
            NSAppleScript.errorMessage: "Not authorized to send Apple events",
        ]
        XCTAssertEqual(ScriptError.mapExecution(info), .notPermitted)
    }
}
