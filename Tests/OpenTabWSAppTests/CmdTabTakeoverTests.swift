import Carbon
import OpenTabWS
import XCTest

/// The takeover against the real WindowServer, inside the granted app. Each
/// test restores before it returns; `readEnabled` is the public
/// `CopySymbolicHotKeys`, the same source the takeover reads the pre-change
/// state from.
@MainActor
final class CmdTabTakeoverTests: XCTestCase {
    private var suite: String!
    private var defaults: UserDefaults!
    private var original: [Int32: Bool] = [:]

    override func setUp() async throws {
        try XCTSkipUnless(CmdTabTakeover.isAvailable, "CGSSetSymbolicHotKeyEnabled unavailable")
        // The suite name is a path, so the plist lands in the temp directory rather
        // than ~/Library/Preferences, where cfprefsd leaves an empty one per test.
        suite = FileManager.default.temporaryDirectory
            .appending(path: "im.opentab.app.tests.ws.\(UUID().uuidString)").path
        defaults = UserDefaults(suiteName: suite)
        original = enabled()
        XCTAssertEqual(original.count, 2)
    }

    /// Whatever the test did, the machine ends up as it was found; a chord
    /// the developer keeps off in System Settings stays off.
    override func tearDown() async throws {
        CmdTabTakeover.setSystemState(original)
        XCTAssertEqual(enabled(), original)
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: URL(filePath: suite + ".plist"))
    }

    private func enabled() -> [Int32: Bool] { readSymbolicHotKeys([1, 2]) }

    func testEnableDisablesSystemChordsAndDisableRestoresThem() {
        let original = enabled()
        XCTAssertEqual(original.count, 2)
        let takeover = CmdTabTakeover(defaults: defaults)
        XCTAssertTrue(takeover.enable())
        XCTAssertEqual(enabled(), [1: false, 2: false])
        XCTAssertEqual(takeover.originalState, original)
        XCTAssertNotNil(defaults.dictionary(forKey: "ws.cmdTab.originalState"), "marker written while disabled")

        takeover.disable()
        XCTAssertEqual(enabled(), original)
        XCTAssertNil(defaults.dictionary(forKey: "ws.cmdTab.originalState"), "marker cleared on a clean restore")
    }

    /// The crash path: the process dies with the chords disabled and the
    /// marker on disk; the next launch replays it before anything else.
    func testRestoreIfCrashedReplaysTheMarkerFromAFreshObject() {
        let original = enabled()
        let takeover = CmdTabTakeover(defaults: defaults)
        XCTAssertTrue(takeover.enable())
        XCTAssertEqual(enabled(), [1: false, 2: false])

        let restored = CmdTabTakeover.restoreIfCrashed(defaults: defaults)
        XCTAssertEqual(restored, original)
        XCTAssertEqual(enabled(), original)
        XCTAssertNil(CmdTabTakeover.restoreIfCrashed(defaults: defaults), "a second replay has nothing to do")
        takeover.disable()
        XCTAssertEqual(enabled(), original)
    }

    func testRestoreCommandWithoutMarkerEnablesEverything() {
        let takeover = CmdTabTakeover(defaults: defaults)
        XCTAssertTrue(takeover.enable())
        defaults.removeObject(forKey: "ws.cmdTab.originalState")
        let written = CmdTabTakeover.runRestoreCommand(defaults: defaults)
        XCTAssertEqual(written, [1: true, 2: true])
        XCTAssertEqual(enabled(), [1: true, 2: true])
        takeover.disable()
    }

    func testDefaultIsOff() {
        XCTAssertFalse(CmdTabTakeover.isConfigured(defaults))
    }

    private func readSymbolicHotKeys(_ ids: [Int32]) -> [Int32: Bool] {
        var array: Unmanaged<CFArray>?
        guard CopySymbolicHotKeys(&array) == noErr,
              let entries = array?.takeRetainedValue() as? [[String: Any]] else { return [:] }
        var result: [Int32: Bool] = [:]
        for id in ids where Int(id) < entries.count {
            result[id] = entries[Int(id)][kHISymbolicHotKeyEnabled as String] as? Bool ?? false
        }
        return result
    }
}
