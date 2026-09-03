import Foundation
import OpenTabCore
import XCTest
@testable import OpenTab

/// H7: L5 forbids removing a row on an empty read, which is what keeps the
/// list from flickering and also what guarantees rows will eventually be left
/// behind. "Rebuild Index" is the way out, so these tests manufacture the two
/// rows nothing else can reach and prove it clears them.
@MainActor
final class RebuildIndexTests: XCTestCase {
    private var harness: CoordinatorHarness!

    override func setUp() async throws {
        harness = CoordinatorHarness(live: [])
        harness.directory.set(apps: [notes])
    }

    private func axWindow(_ elementID: UInt64, title: String, onActiveSpace: Bool = true) -> WindowSnapshot {
        WindowSnapshot(key: .ax(pid: notes.pid, elementID: elementID), app: notes, title: title,
                       subrole: "AXStandardWindow", isMinimized: false, isOnActiveSpace: onActiveSpace)
    }

    /// The app is still running and has stopped answering with windows. Every
    /// later read is empty, and an empty read never removes (L5).
    func testEmptyReadsLeaveRowsNothingElseCanRemove() async {
        harness.source.set([axWindow(1, title: "Groceries"), axWindow(2, title: "Recipes")], for: notes)
        await harness.coordinator.refreshEverything(seedFocus: true)
        XCTAssertEqual(harness.entries.count, 2)

        harness.source.set([], for: notes)
        for _ in 0..<10 {
            await harness.coordinator.handle(.periodic)
        }
        XCTAssertEqual(harness.entries.count, 2, "an empty read must not remove a row")

        await harness.coordinator.rebuild()
        XCTAssertTrue(harness.entries.isEmpty, "Rebuild Index must clear rows the reads no longer list")
    }

    /// The harder one: a window the source once reported off the active Space.
    /// A non-empty read leaves it alone (it would be invisible to Accessibility
    /// either way) and the WindowServer sweep only judges `.cg` keys, so
    /// nothing in the running app can ever take this row out.
    func testRebuildClearsAnOffSpaceRowTheSweepCannotJudge() async {
        harness.source.set([axWindow(1, title: "Groceries"),
                            axWindow(2, title: "Recipes", onActiveSpace: false)], for: notes)
        await harness.coordinator.refreshEverything(seedFocus: true)
        XCTAssertEqual(harness.entries.count, 2)

        // The off-space window is gone for good; the app keeps reporting the
        // other one.
        harness.source.set([axWindow(1, title: "Groceries")], for: notes)
        harness.setLive([])
        for _ in 0..<10 {
            await harness.coordinator.handle(.periodic)
        }
        XCTAssertEqual(harness.entries.count, 2, "neither a fresh read nor the sweep can reach this row")

        await harness.coordinator.rebuild()
        XCTAssertEqual(harness.entries.map(\.title), ["Groceries"],
                       "Rebuild Index must drop the stale row and keep the live one")
    }

    /// Rebuilding also clears the coordinator's own per-app marks, so a
    /// browser that was marked unreadable is not stuck that way.
    func testRebuildClearsTheUnresponsiveMark() async {
        harness.source.set([axWindow(1, title: "Groceries")], for: notes)
        await harness.coordinator.refreshEverything()
        harness.source.fail(notes, with: .deadlineExceeded)
        await harness.coordinator.refresh(app: notes)
        XCTAssertEqual(harness.rows.first?.status, .unresponsive)

        harness.source.fail(notes, with: nil)
        await harness.coordinator.rebuild()
        XCTAssertEqual(harness.rows.first?.status, .normal)
    }
}
