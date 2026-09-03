import XCTest
@testable import OpenTabWS

final class RemoteTokenTests: XCTestCase {
    /// E0 §3: Chrome pid 996 dumps as `e4030000`, the magic as `6f636f63`.
    func testSynthesizedPrefixMatchesDocumentedLayout() {
        let prefix = RemoteToken.synthesizedPrefix(pid: 996)
        XCTAssertEqual(prefix, [0xe4, 0x03, 0x00, 0x00, 0, 0, 0, 0, 0x6f, 0x63, 0x6f, 0x63])
    }

    func testElementIDIsLittleEndianAtOffset12() {
        let token = RemoteToken(prefix: RemoteToken.synthesizedPrefix(pid: 996), elementID: 2639)
        XCTAssertEqual(token.bytes.count, 20)
        XCTAssertEqual(Array(token.bytes[12...]), [0x4f, 0x0a, 0, 0, 0, 0, 0, 0])
        XCTAssertEqual(token.elementID, 2639)
        XCTAssertEqual(token.pid, 996)
    }

    func testParseRoundTrips() throws {
        let original = RemoteToken(prefix: RemoteToken.synthesizedPrefix(pid: 53360), elementID: 43)
        let parsed = try XCTUnwrap(RemoteToken(bytes: original.bytes))
        XCTAssertEqual(parsed, original)
        XCTAssertEqual(parsed.pid, 53360)
        XCTAssertEqual(parsed.prefix, original.prefix)
    }

    func testRejectsWrongLengthOrMagic() {
        XCTAssertNil(RemoteToken(bytes: Array(repeating: 0, count: 19)))
        var bytes = RemoteToken(prefix: RemoteToken.synthesizedPrefix(pid: 1), elementID: 1).bytes
        bytes[8] = 0
        XCTAssertNil(RemoteToken(bytes: bytes))
    }
}
