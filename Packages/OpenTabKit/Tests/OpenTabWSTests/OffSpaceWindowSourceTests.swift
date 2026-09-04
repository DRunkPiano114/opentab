import ApplicationServices
import CoreGraphics
import OpenTabAX
import OpenTabCore
import XCTest
@testable import OpenTabWS

/// The merge logic of the off-space source against a fake backend: what the
/// WindowServer lists, what AX returned, what the token probe can reach, and
/// which Spaces are active are all scripted, so what a failed scan and an
/// empty read are allowed to remove is checked without a target process.
final class OffSpaceWindowSourceTests: XCTestCase {
    private let app = AppInfo(bundleID: "com.example.chrome", pid: 996, localizedName: "Chrome")
    private let far = ContinuousClock.now + .seconds(60)

    /// Mutable world the backend closures read.
    final class World: @unchecked Sendable {
        var rows: [WindowRow] = []
        var rowsUnknown = false
        var activeSpaces: Set<UInt64>? = [3, 829]
        var spaces: [CGWindowID: [UInt64]] = [:]
        /// element id → window id the probe answers, and the element ids with role AXWindow.
        var elements: [UInt64: CGWindowID] = [:]
        var windowRoles: Set<UInt64> = []
        var reads: [CGWindowID: WindowRead] = [:]
        var verifyFails: Set<CGWindowID> = []
        var focused: CGWindowID?
        var probes = 0
        /// wid encoded in the fake element so verify/read can find their window.
        var elementWindow: [RemoteElement: CGWindowID] = [:]
    }

    private let world = World()

    private func row(_ id: CGWindowID, layer: Int32 = 0, size: CGFloat = 800, alpha: Double = 1,
                     onscreen: Bool = false) -> WindowRow {
        WindowRow(id: id, pid: 996, layer: layer, bounds: CGRect(x: 0, y: 0, width: size, height: size),
                  alpha: alpha, isOnscreen: onscreen)
    }

    private func backend() -> OffSpaceBackend {
        let world = world
        return OffSpaceBackend(
            rows: { _ in world.rowsUnknown ? nil : world.rows },
            activeSpaces: { world.activeSpaces },
            spacesOfWindow: { world.spaces[$0] ?? [] },
            prefix: { RemoteToken.synthesizedPrefix(pid: $0) },
            makeElement: { _, elementID in
                // A distinct local element per id; never messaged.
                let element = RemoteElement(AXUIElementCreateApplication(pid_t(1_000_000 + elementID)))
                if let wid = world.elements[elementID] { world.elementWindow[element] = wid }
                return element
            },
            probe: { _ in
                ElementScanner.Probe(windowID: { id in world.probes += 1; return world.elements[id] },
                                     isWindow: { world.windowRoles.contains($0) })
            },
            verify: { element, wid in world.elementWindow[element] == wid && !world.verifyFails.contains(wid) },
            read: { element in
                guard let wid = world.elementWindow[element] else { return .unreadable }
                return world.reads[wid] ?? .unreadable
            },
            focusedWindowID: { _ in world.focused })
    }

    private func source(maxElementID: UInt64 = 100) -> OffSpaceWindowSource {
        var configuration = OffSpaceConfiguration()
        configuration.maxElementID = maxElementID
        configuration.scanBudget = .seconds(10)
        let availability = OffSpaceAvailability(tokenPath: true, spaceMap: true, missingSymbols: [])
        return OffSpaceWindowSource(base: AXWindowSource(), backend: backend(),
                                    availability: availability, configuration: configuration)
    }

    private func axSnapshot(_ id: CGWindowID, minimized: Bool = false) -> WindowSnapshot {
        WindowSnapshot(key: .cg(id), app: app, title: "ax \(id)", subrole: "AXStandardWindow",
                       isMinimized: minimized, isOnActiveSpace: true, level: 0, isFocused: false)
    }

    private func keys(_ snapshots: [WindowSnapshot]) -> Set<WindowKey> { Set(snapshots.map(\.key)) }

    // MARK: Tests

    func testAXWindowsGetSpaceMembershipFromCGS() {
        world.rows = [row(91), row(82)]
        world.spaces = [91: [3], 82: [1088]]
        let result = source().augment([axSnapshot(91), axSnapshot(82)], of: app, deadline: far)
        XCTAssertEqual(result.first { $0.key == .cg(91) }?.isOnActiveSpace, true)
        XCTAssertEqual(result.first { $0.key == .cg(82) }?.isOnActiveSpace, false)
        XCTAssertEqual(world.probes, 0, "windows AX returned are never scanned for")
    }

    func testWindowAXCannotSeeIsReachedThroughTheTokenScan() {
        world.rows = [row(91), row(82)]
        world.spaces = [91: [3], 82: [1088]]
        world.elements = [2: 82, 5: 82]           // id 2 is a descendant, id 5 the window
        world.windowRoles = [5]
        world.reads = [82: .window(subrole: "AXStandardWindow", title: "Perplexity", isMinimized: false)]
        world.focused = 82
        let source = source()
        let result = source.augment([axSnapshot(91)], of: app, deadline: far)
        XCTAssertEqual(keys(result), [.cg(91), .cg(82)])
        let reached = result.first { $0.key == .cg(82) }!
        XCTAssertEqual(reached.title, "Perplexity")
        XCTAssertFalse(reached.isOnActiveSpace)
        XCTAssertTrue(reached.isFocused)
        XCTAssertEqual(reached.level, 0)
        XCTAssertEqual(source.report(for: 996)?.reachedViaToken, 1)
        XCTAssertEqual(source.hitElementIDs().first?.elementIDs, [5])
        XCTAssertNotNil(source.reachedElement(for: .cg(82)), "the activator needs the element")
    }

    /// A scan that fails to reach a window it reached before keeps the last
    /// snapshot as long as the WindowServer still lists the window.
    func testUnreachedWindowKeepsItsLastSnapshotWhileWindowServerListsIt() {
        world.rows = [row(82)]
        world.spaces = [82: [1088]]
        world.elements = [5: 82]
        world.windowRoles = [5]
        world.reads = [82: .window(subrole: "AXStandardWindow", title: "Perplexity", isMinimized: false)]
        let source = source(maxElementID: 10)
        XCTAssertEqual(keys(source.augment([], of: app, deadline: far)), [.cg(82)])

        world.verifyFails = [82]
        world.elements = [:]
        let again = source.augment([], of: app, deadline: far)
        XCTAssertEqual(keys(again), [.cg(82)], "a miss is not evidence the window is gone")
        XCTAssertEqual(again.first?.title, "Perplexity")
        XCTAssertEqual(source.report(for: 996)?.keptUnreached, 1)
        XCTAssertEqual(source.report(for: 996)?.exhausted, 1)
        XCTAssertNil(source.reachedElement(for: .cg(82)), "a stale element is not offered for activation")
    }

    func testWindowGoneFromWindowServerIsDropped() {
        world.rows = [row(82)]
        world.spaces = [82: [1088]]
        world.elements = [5: 82]
        world.windowRoles = [5]
        world.reads = [82: .window(subrole: "AXStandardWindow", title: "t", isMinimized: false)]
        let source = source()
        _ = source.augment([], of: app, deadline: far)
        world.rows = []
        XCTAssertTrue(source.augment([], of: app, deadline: far).isEmpty)
        XCTAssertNil(source.reachedElement(for: .cg(82)))
    }

    func testNonListableWindowIsFilteredOnceAndNotRescanned() {
        world.rows = [row(70)]
        world.spaces = [70: [1088]]
        world.elements = [4: 70]
        world.windowRoles = [4]
        world.reads = [70: .notListable("subrole:AXFloatingWindow")]
        let source = source()
        XCTAssertTrue(source.augment([], of: app, deadline: far).isEmpty)
        let probes = world.probes
        XCTAssertTrue(source.augment([], of: app, deadline: far).isEmpty)
        XCTAssertEqual(world.probes, probes, "a filtered window costs no further probes")
        XCTAssertEqual(source.report(for: 996)?.filtered, 0, "counted only when it happened")
    }

    /// Shadows and fragments at layer 0 are not windows.
    func testJunkRowsAreNotCandidates() {
        world.rows = [row(1, size: 10), row(2, alpha: 0), row(3, layer: 25), row(4, size: 10, alpha: 0)]
        let source = source()
        XCTAssertTrue(source.augment([], of: app, deadline: far).isEmpty)
        XCTAssertEqual(world.probes, 0)
        XCTAssertEqual(source.report(for: 996)?.candidates, 0)
    }

    /// An ordered-out window the app keeps around sits at layer 0 on no
    /// Space. It is not a switch target and must not cost a scan.
    func testRowOnNoSpaceIsNotACandidate() {
        world.rows = [row(91), row(43604)]
        world.spaces = [91: [3]]
        world.elements = [7: 43604]
        world.windowRoles = [7]
        world.reads = [43604: .window(subrole: "AXStandardWindow", title: "hidden", isMinimized: false)]
        let source = source()
        let result = source.augment([axSnapshot(91)], of: app, deadline: far)
        XCTAssertEqual(keys(result), [.cg(91)])
        XCTAssertEqual(world.probes, 0)
        XCTAssertEqual(source.report(for: 996)?.noSpace, 1)
        XCTAssertEqual(source.report(for: 996)?.candidates, 0)
    }

    /// A fullscreen transition leaves the window on no Space for about a
    /// second. A window read moments ago keeps its row through that; one
    /// that stays on no Space past the grace is ordered out and dropped.
    func testKnownWindowOnNoSpaceIsKeptWithinGraceThenDropped() {
        world.rows = [row(91), row(82)]
        world.spaces = [91: [3], 82: [1088]]
        world.elements = [5: 82]
        world.windowRoles = [5]
        world.reads = [82: .window(subrole: "AXStandardWindow", title: "t", isMinimized: false)]
        let source = source()
        let start = ContinuousClock.now
        source.clock = { start }
        XCTAssertEqual(keys(source.augment([axSnapshot(91)], of: app, deadline: far)), [.cg(91), .cg(82)])

        world.spaces[82] = []
        source.clock = { start + .seconds(1) }
        let during = source.augment([axSnapshot(91)], of: app, deadline: far)
        XCTAssertEqual(keys(during), [.cg(91), .cg(82)], "mid-transition the row stays")
        XCTAssertEqual(source.report(for: 996)?.keptUnreached, 1)
        XCTAssertEqual(source.report(for: 996)?.noSpace, 0)

        source.clock = { start + .seconds(11) }
        let after = source.augment([axSnapshot(91)], of: app, deadline: far)
        XCTAssertEqual(keys(after), [.cg(91)], "past the grace it is an ordered-out window")
        XCTAssertEqual(source.report(for: 996)?.noSpace, 1)
        XCTAssertNil(source.reachedElement(for: .cg(82)))
    }

    /// A failed `CGWindowListCopyWindowInfo` is not a window list. Nothing is
    /// pruned on it and every known window stands in.
    func testUnknownWindowListKeepsEverythingAndPrunesNothing() {
        world.rows = [row(91), row(82)]
        world.spaces = [91: [3], 82: [1088]]
        world.elements = [5: 82]
        world.windowRoles = [5]
        world.reads = [82: .window(subrole: "AXStandardWindow", title: "t", isMinimized: false)]
        let source = source()
        _ = source.augment([axSnapshot(91)], of: app, deadline: far)
        world.rowsUnknown = true
        let probes = world.probes
        let result = source.augment([axSnapshot(91)], of: app, deadline: far)
        XCTAssertEqual(keys(result), [.cg(91), .cg(82)])
        XCTAssertEqual(world.probes, probes)
        XCTAssertEqual(source.report(for: 996)?.windowListUnknown, true)
        XCTAssertNotNil(source.reachedElement(for: .cg(82)), "the element is not pruned on no evidence")
    }

    /// A snapshot re-emitted from the cache must not outrank the window AX
    /// reports as focused now.
    func testCachedSnapshotNeverClaimsFocus() {
        world.rows = [row(91), row(82)]
        world.spaces = [91: [3], 82: [1088]]
        world.elements = [5: 82]
        world.windowRoles = [5]
        world.reads = [82: .window(subrole: "AXStandardWindow", title: "t", isMinimized: false)]
        world.focused = 82
        let source = source(maxElementID: 10)
        XCTAssertEqual(source.augment([axSnapshot(91)], of: app, deadline: far).first { $0.key == .cg(82) }?.isFocused, true)
        world.verifyFails = [82]
        world.elements = [:]
        let kept = source.augment([axSnapshot(91)], of: app, deadline: far).first { $0.key == .cg(82) }
        XCTAssertNotNil(kept)
        XCTAssertEqual(kept?.isFocused, false)
    }

    /// On the active Space, not on screen, not listed by AX (which lists
    /// minimized windows): an ordered-out window with a Space left over.
    func testOrderedOutRowOnActiveSpaceIsNotACandidate() {
        world.rows = [row(91, onscreen: true), row(70, onscreen: false), row(82, onscreen: false)]
        world.spaces = [91: [3], 70: [3], 82: [1088]]
        world.elements = [4: 70, 5: 82]
        world.windowRoles = [4, 5]
        world.reads = [70: .window(subrole: "AXStandardWindow", title: "hidden", isMinimized: false),
                       82: .window(subrole: "AXStandardWindow", title: "off-space", isMinimized: false)]
        let source = source()
        let result = source.augment([axSnapshot(91)], of: app, deadline: far)
        XCTAssertEqual(keys(result), [.cg(91), .cg(82)])
        XCTAssertEqual(source.report(for: 996)?.orderedOut, 1)
    }

    /// Without CGS the pre-filter cannot run; the scan is the only evidence.
    func testWithoutSpaceMapEveryLayerZeroRowIsScanned() {
        world.activeSpaces = nil
        world.rows = [row(43604)]
        world.elements = [7: 43604]
        world.windowRoles = [7]
        world.reads = [43604: .window(subrole: "AXStandardWindow", title: "t", isMinimized: false)]
        let result = source().augment([], of: app, deadline: far)
        XCTAssertEqual(keys(result), [.cg(43604)])
    }

    func testDeadlineAlreadyPassedStillReturnsWhatIsKnown() {
        world.rows = [row(91), row(82)]
        world.spaces = [91: [3], 82: [1088]]
        world.elements = [5: 82]
        world.windowRoles = [5]
        world.reads = [82: .window(subrole: "AXStandardWindow", title: "t", isMinimized: false)]
        let source = source()
        _ = source.augment([axSnapshot(91)], of: app, deadline: far)
        world.verifyFails = [82]
        let result = source.augment([axSnapshot(91)], of: app, deadline: .now - .seconds(1))
        XCTAssertEqual(keys(result), [.cg(91), .cg(82)])
        XCTAssertEqual(source.report(for: 996)?.probed, 0)
    }

    /// Without CGS, a window AX returned is on the active Space and one only a
    /// token reached is not: the reach path is the evidence.
    func testWithoutSpaceMapReachPathDecidesMembership() {
        world.activeSpaces = nil
        world.rows = [row(91), row(82)]
        world.elements = [5: 82]
        world.windowRoles = [5]
        world.reads = [82: .window(subrole: "AXStandardWindow", title: "t", isMinimized: false)]
        let result = source().augment([axSnapshot(91)], of: app, deadline: far)
        XCTAssertEqual(result.first { $0.key == .cg(91) }?.isOnActiveSpace, true)
        XCTAssertEqual(result.first { $0.key == .cg(82) }?.isOnActiveSpace, false)
    }

    /// The empty-Space fallback through the whole path: a minimized window
    /// with no Space stays on the active Space; the same window not minimized
    /// does not.
    func testEmptySpaceListFallsBackToMinimizedFlag() {
        world.rows = [row(121), row(122)]
        world.spaces = [:]
        let result = source().augment([axSnapshot(121, minimized: true), axSnapshot(122)], of: app, deadline: far)
        XCTAssertEqual(result.first { $0.key == .cg(121) }?.isOnActiveSpace, true)
        XCTAssertEqual(result.first { $0.key == .cg(122) }?.isOnActiveSpace, false)
    }

    func testWindowThatBecomesVisibleToAXDropsItsTokenElement() {
        world.rows = [row(82)]
        world.spaces = [82: [1088]]
        world.elements = [5: 82]
        world.windowRoles = [5]
        world.reads = [82: .window(subrole: "AXStandardWindow", title: "t", isMinimized: false)]
        let source = source()
        _ = source.augment([], of: app, deadline: far)
        XCTAssertNotNil(source.reachedElement(for: .cg(82)))
        let result = source.augment([axSnapshot(82)], of: app, deadline: far)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.title, "ax 82")
        XCTAssertNil(source.reachedElement(for: .cg(82)), "the pure-AX activator owns it now")
    }
}
