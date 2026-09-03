import AppKit
import OpenTabCore
import SwiftUI
import XCTest
@testable import OpenTab

/// Renders the real panel view, taller than its window so the list scrolls
/// and rows get rebuilt as the selection walks down, and counts highlighted
/// rows by scanning the row-background column. A stale highlight in a lazily
/// built row shows up as a second band.
@MainActor
final class PanelSelectionTests: XCTestCase {
    private var window: NSWindow!
    private var model: PanelViewModel!
    private var hosting: NSHostingView<SwitcherRootView>!
    private let rowCount = 30

    override func setUp() async throws {
        model = PanelViewModel()
        model.present(rows: PanelViewModel.Row.placeholders(count: rowCount), selectedIndex: 1)
        let size = PanelController.Metrics.size(rowCount: rowCount, visibleHeight: 560)
        hosting = NSHostingView(rootView: SwitcherRootView(model: model))
        hosting.sizingOptions = []
        window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -10_000, y: -10_000), size: size),
                          styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.orderFrontRegardless()
        settle()
    }

    override func tearDown() async throws {
        window.orderOut(nil)
        window.close()
    }

    func testHeldKeyWalkKeepsExactlyOneHighlight() {
        XCTAssertEqual(highlightedBands(), 1)
        // The same cadence as the Tab auto-repeat, past the visible rows and back.
        for target in Array(2...20) + [0, rowCount - 1, 7] {
            model.rows = model.rows
            model.select(target, source: .keyboard)
            settle()
            XCTAssertEqual(highlightedBands(), 1, "selectedIndex=\(target)")
        }
    }

    func testHoverThenKeyKeepsExactlyOneHighlight() {
        model.select(7, source: .pointer)
        settle()
        model.select(8, source: .keyboard)
        settle()
        XCTAssertEqual(highlightedBands(), 1)
    }

    /// Only the run loop turns: forcing layout here would re-evaluate rows the
    /// real app never touches and hide exactly the staleness being tested.
    private func settle() {
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.06))
    }

    /// Number of contiguous lit stretches down a column just inside the row
    /// rectangle and left of the icon, where only the panel background
    /// (#0A0A0A) or the selection fill (#333333) can be.
    private func highlightedBands() -> Int {
        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
            XCTFail("no bitmap"); return -1
        }
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        let scale = CGFloat(rep.pixelsWide) / hosting.bounds.width
        let x = Int((Theme.contentInsetH + 3) * scale)
        let listTop = Int((PanelController.Metrics.topPad + PanelController.Metrics.fieldHeight
                           + PanelController.Metrics.fieldListGap) * scale)
        var bands = 0
        var lit = false
        for y in listTop..<(rep.pixelsHigh - Int(PanelController.Metrics.bottomPad * scale)) {
            let isLit = (rep.colorAt(x: x, y: y)?.redComponent ?? 0) > 0.12
            if isLit, !lit { bands += 1 }
            lit = isLit
        }
        return bands
    }
}
