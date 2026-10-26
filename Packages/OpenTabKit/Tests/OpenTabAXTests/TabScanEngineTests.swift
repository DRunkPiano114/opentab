import CoreGraphics
import OpenTabCore
import XCTest
@testable import OpenTabAX

/// A forest of windows. A window node's id is its CGWindowID times 1 000;
/// its tab buttons follow it. Every title is invented.
private struct Windows: TabTreeSource {
    typealias Node = Int

    struct Window {
        var tabs: [String]
        var active: Int?
        /// The window node does not answer, like a remote element that went stale.
        var unreadable = false
        var role = "AXWindow"
    }

    var windows: [CGWindowID: Window]

    static func node(_ id: CGWindowID) -> Int { Int(id) * 1_000 }

    func attributes(of node: Int) -> TabNodeAttributes? {
        let (wid, offset) = (CGWindowID(node / 1_000), node % 1_000)
        guard let window = windows[wid], !window.unreadable else { return nil }
        if offset == 0 {
            return TabNodeAttributes(role: window.role, subrole: "AXStandardWindow", title: "", description: "",
                                     isSelected: false)
        }
        let index = offset - 1
        guard window.tabs.indices.contains(index) else { return nil }
        return TabNodeAttributes(role: "AXRadioButton", subrole: "AXTabButton", title: window.tabs[index],
                                 description: "", isSelected: index == window.active)
    }

    func children(of node: Int, limit: Int) -> [Int] {
        guard node % 1_000 == 0, let window = windows[CGWindowID(node / 1_000)] else { return [] }
        return window.tabs.indices.map { node + $0 + 1 }.prefix(limit).map { $0 }
    }
}

final class TabScanEngineTests: XCTestCase {
    private let far = ContinuousClock.now + .seconds(3_600)

    private func engine(_ windows: [CGWindowID: Windows.Window], layers: [CGWindowID: Int32]? = nil)
        -> TabScanEngine<Windows> {
        let layers = layers ?? windows.mapValues { _ in 0 }
        let source = Windows(windows: windows)
        return TabScanEngine(source: source,
                             // Read apart from the walk: a window can pass this
                             // filter and stop answering before its tree is read.
                             isListable: { windows[CGWindowID($0 / 1_000)]?.role == "AXWindow" },
                             windowID: { CGWindowID($0 / 1_000) },
                             layer: { layers[$0] })
    }

    private func node(_ id: CGWindowID) -> Int { Windows.node(id) }

    // MARK: Windows Accessibility lists

    func testSnapshotsAreKeyedByWindowNumberWithPositionalTokensAndOneActiveTab() throws {
        let engine = engine([91: .init(tabs: ["alpha", "beta", "gamma"], active: 1)])
        let scan = try engine.scan(.init(axWindows: [node(91)]), deadline: far)
        XCTAssertEqual(scan.snapshots.map(\.windowKey), [.cg(91), .cg(91), .cg(91)])
        XCTAssertEqual(scan.snapshots.map(\.token), ["0", "1", "2"])
        XCTAssertEqual(scan.snapshots.map(\.title), ["alpha", "beta", "gamma"])
        XCTAssertEqual(scan.snapshots.filter(\.isActive).map(\.token), ["1"])
        XCTAssertEqual(scan.tabs[91]?.count, 3)
    }

    func testNoWindowAtAllIsNoEvidence() {
        XCTAssertThrowsError(try engine([:]).scan(.init(axWindows: []), deadline: far)) {
            XCTAssertEqual($0 as? AXSourceError, .cannotComplete)
        }
    }

    func testUnreadableWindowAloneIsNoEvidence() {
        let engine = engine([91: .init(tabs: ["alpha"], active: 0, unreadable: true)])
        XCTAssertThrowsError(try engine.scan(.init(axWindows: [node(91)]), deadline: far)) {
            XCTAssertEqual($0 as? AXSourceError, .cannotComplete)
        }
    }

    /// A complete scan that finds no tab strip is a real answer: the app has
    /// no tabs right now.
    func testCompleteScanWithoutTabsReportsNone() throws {
        let scan = try engine([91: .init(tabs: [], active: nil)]).scan(.init(axWindows: [node(91)]), deadline: far)
        XCTAssertTrue(scan.snapshots.isEmpty)
        XCTAssertEqual(scan.windowsScanned, 1)
    }

    func testWindowsOffLayerZeroOrNotListableAreSkipped() throws {
        let engine = engine([91: .init(tabs: ["alpha"], active: 0),
                             92: .init(tabs: ["beta"], active: 0),
                             93: .init(tabs: ["gamma"], active: 0, role: "AXSheet")],
                            layers: [91: 0, 92: 3, 93: 0])
        let scan = try engine.scan(.init(axWindows: [node(91), node(92), node(93)]), deadline: far)
        XCTAssertEqual(Set(scan.snapshots.map(\.windowKey)), [.cg(91)])
        XCTAssertEqual(scan.windowsScanned, 1)
    }
}
