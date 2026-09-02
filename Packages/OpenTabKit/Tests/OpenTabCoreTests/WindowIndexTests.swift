import XCTest
@testable import OpenTabCore

@MainActor
final class WindowIndexTests: XCTestCase {
    let safari = app("Safari", pid: 100)
    let xcode = app("Xcode", pid: 200)
    var source = FakeWindowSource()
    var directory = FakeAppDirectory()

    override func setUp() async throws {
        source = FakeWindowSource()
        directory = FakeAppDirectory()
        directory.set(apps: [safari, xcode])
        source.set([window(1, safari, focused: true), window(2, safari)], for: safari)
        source.set([window(3, xcode, focused: true)], for: xcode)
    }

    func makeIndex() -> WindowIndex {
        WindowIndex(source: source, directory: directory)
    }

    func testRefreshAllReadsEveryApp() async {
        let index = makeIndex()
        await index.refreshAll()
        XCTAssertEqual(Set(index.entries.map(\.key)), [.cg(1), .cg(2), .cg(3)])
    }

    func testActivationOrdersByRecency() async {
        let index = makeIndex()
        await index.refreshAll()
        await index.handle(.appActivated(xcode, FocusGeneration(raw: 1)))
        await index.handle(.appActivated(safari, FocusGeneration(raw: 2)))
        XCTAssertEqual(index.entries.map(\.key), [.cg(1), .cg(3), .cg(2)])
    }

    func testStaleFocusBumpIsDropped() async {
        let index = makeIndex()
        await index.refreshAll()
        await index.handle(.appActivated(safari, FocusGeneration(raw: 5)))
        await index.handle(.appActivated(xcode, FocusGeneration(raw: 3)))
        XCTAssertEqual(index.entries.first?.key, .cg(1), "generation 3 arrived after 5 and must not win")
    }

    func testTerminatedAppDisappears() async {
        let index = makeIndex()
        await index.refreshAll()
        await index.handle(.appTerminated(xcode))
        XCTAssertEqual(Set(index.entries.map(\.key)), [.cg(1), .cg(2)])
    }

    func testFailedReadLeavesStoreUntouched() async {
        let index = makeIndex()
        await index.refreshAll()
        source.fail(safari)
        source.set([window(9, safari)], for: safari)
        await index.refresh(app: safari)
        XCTAssertEqual(Set(index.entries.map(\.key)), [.cg(1), .cg(2), .cg(3)])
    }

    func testOlderReadCannotOverwriteNewerOne() async {
        let index = makeIndex()
        await index.refreshAll()
        source.delay(safari, .milliseconds(30))
        source.set([window(1, safari)], for: safari)
        let slow = Task { await index.refresh(app: safari) }
        try? await Task.sleep(for: .milliseconds(5))
        source.delay(safari, .zero)
        source.set([window(1, safari), window(2, safari), window(4, safari)], for: safari)
        await index.refresh(app: safari)
        await slow.value
        XCTAssertEqual(Set(index.entries.filter { $0.app == safari }.map(\.key)), [.cg(1), .cg(2), .cg(4)])
    }

    func testHiddenEventsUpdateEntries() async {
        let index = makeIndex()
        await index.refreshAll()
        await index.handle(.appHidden(safari))
        XCTAssertTrue(index.entries.filter { $0.app == safari }.allSatisfy(\.isHidden))
        await index.handle(.appUnhidden(safari))
        XCTAssertFalse(index.entries.contains { $0.isHidden })
    }

    func testRebuildClearsZombies() async {
        let index = makeIndex()
        await index.refreshAll()
        source.set([], for: xcode)
        await index.refresh(app: xcode)
        XCTAssertTrue(index.entries.contains { $0.key == .cg(3) }, "empty read keeps the row (L5)")
        await index.rebuild()
        XCTAssertFalse(index.entries.contains { $0.key == .cg(3) })
    }

    func testEventsFromTriggerDriveTheIndex() async {
        let index = makeIndex()
        let trigger = FakeRefreshTrigger()
        var changes = 0
        let changed = expectation(description: "store changed")
        index.onChange = { changes += 1; if changes == 1 { changed.fulfill() } }
        index.start(trigger: trigger)
        trigger.send(.appLaunched(xcode))
        await fulfillment(of: [changed], timeout: 1)
        XCTAssertEqual(index.entries.map(\.key), [.cg(3)])
        index.stop()
        trigger.finish()
    }
}
