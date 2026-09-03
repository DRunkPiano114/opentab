import XCTest
@testable import OpenTabWS

final class CmdTabRecoveryTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suite: String!
    private let writes = Writes()

    final class Writes: @unchecked Sendable {
        private let lock = NSLock()
        private var log: [(Int32, Bool)] = []
        func record(_ id: Int32, _ enabled: Bool) { lock.lock(); log.append((id, enabled)); lock.unlock() }
        var all: [(Int32, Bool)] { lock.lock(); defer { lock.unlock() }; return log }
        var byID: [Int32: Bool] { Dictionary(all, uniquingKeysWith: { _, last in last }) }
    }

    override func setUp() {
        suite = "im.opentab.app.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
    }

    private func recovery() -> CmdTabRecovery {
        let writes = writes
        return CmdTabRecovery(defaults: defaults) { id, enabled in writes.record(id, enabled); return true }
    }

    func testMarkerIsWrittenBeforeAnyChangeAndReplayedExactly() {
        recovery().remember(original: [1: true, 2: false])
        XCTAssertEqual(recovery().marker, [1: true, 2: false])
        XCTAssertTrue(writes.all.isEmpty, "remembering must not touch the hotkeys")

        let restored = recovery().restoreIfCrashed()
        XCTAssertEqual(restored, [1: true, 2: false])
        XCTAssertEqual(writes.byID, [1: true, 2: false], "a hotkey the user had off stays off (E2 requirement 2)")
        XCTAssertNil(recovery().marker, "the marker is cleared once replayed")
    }

    func testNoMarkerIsANoOp() {
        XCTAssertNil(recovery().restoreIfCrashed())
        XCTAssertTrue(writes.all.isEmpty)
    }

    func testForceRestoreEnablesWhenNothingIsRemembered() {
        let result = recovery().forceRestore(ids: [1, 2])
        XCTAssertEqual(result, [1: true, 2: true])
        XCTAssertEqual(writes.byID, [1: true, 2: true])
    }

    func testForceRestorePrefersTheMarker() {
        recovery().remember(original: [1: false, 2: true])
        XCTAssertEqual(recovery().forceRestore(ids: [1, 2]), [1: false, 2: true])
        XCTAssertEqual(writes.byID, [1: false, 2: true])
    }

    func testCorruptMarkerIsIgnored() {
        defaults.set("garbage", forKey: CmdTabRecovery.markerKey)
        XCTAssertNil(recovery().restoreIfCrashed())
    }
}
