import CoreGraphics
import OpenTabWS
import XCTest

/// The private-symbol contract on this machine. A missing symbol is the
/// expected degradation path (L10); these tests document which path the
/// product is on, and check the one symbol E0 did not verify.
final class WSSymbolTests: XCTestCase {
    func testEverySymbolResolvesOnThisSystem() {
        let table = OffSpaceDiagnostics.symbolTable()
        XCTAssertEqual(table.count, 9)
        let missing = table.filter { $0.contains("MISSING") }
        XCTAssertTrue(missing.isEmpty, "unresolved: \(missing)")
    }

    func testCGSGetWindowLevelAgreesWithPublicWindowLayer() {
        let result = OffSpaceDiagnostics.verifyWindowLevel(sample: 40)
        XCTAssertGreaterThan(result.compared, 0, result.verdict)
        XCTAssertEqual(result.agreed, result.compared, result.verdict)
    }
}
