import AppKit
import OpenTabCore
import SwiftUI
import XCTest
@testable import OpenTab

/// Renders the real panel view in a window shorter than its list and reads
/// the scroll offset straight from the backing scroll view. Pointer
/// selections must leave the offset alone; keyboard selections may move it,
/// and only when the selected row is not already fully visible.
@MainActor
final class PanelScrollTests: XCTestCase {
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

    func testPointerSelectionNeverScrolls() throws {
        let scroll = try XCTUnwrap(scrollView())
        let before = scroll.contentView.bounds.origin.y
        for target in [3, 5, lastVisibleRow(scroll) + 1, 20, rowCount - 1, 0] {
            model.select(target, source: .pointer)
            settle()
            XCTAssertEqual(model.selectedIndex, target)
            XCTAssertEqual(scroll.contentView.bounds.origin.y, before, "pointer selection of row \(target) scrolled")
        }
    }

    func testKeyboardSelectionScrollsOnlyWhenRowLeavesView() throws {
        let scroll = try XCTUnwrap(scrollView())
        let lastVisible = lastVisibleRow(scroll)
        XCTAssertGreaterThan(lastVisible, 2)
        XCTAssertLessThan(lastVisible, rowCount - 2)

        for target in 2...lastVisible {
            model.select(target, source: .keyboard)
            settle()
            XCTAssertEqual(scroll.contentView.bounds.origin.y, 0, "row \(target) is visible; no scroll expected")
        }

        var previousOffset: CGFloat = 0
        for target in (lastVisible + 1)...(lastVisible + 3) {
            model.select(target, source: .keyboard)
            settle()
            let offset = scroll.contentView.bounds.origin.y
            XCTAssertGreaterThan(offset, previousOffset, "row \(target) was below the view")
            XCTAssertTrue(isFullyVisible(target, in: scroll), "row \(target) not fully visible after scroll")
            XCTAssertTrue(isFullyVisible(target - 1, in: scroll), "list re-centred instead of scrolling minimally")
            previousOffset = offset
        }

        model.select(lastVisible + 1, source: .keyboard)
        settle()
        XCTAssertEqual(scroll.contentView.bounds.origin.y, previousOffset, "row already visible; no scroll expected")

        model.select(0, source: .keyboard)
        settle()
        XCTAssertEqual(scroll.contentView.bounds.origin.y, 0)
    }

    func testPresentRewindsThenRevealsInitialSelection() throws {
        let scroll = try XCTUnwrap(scrollView())
        model.select(rowCount - 1, source: .keyboard)
        settle()
        XCTAssertGreaterThan(scroll.contentView.bounds.origin.y, 0)

        model.present(rows: PanelViewModel.Row.placeholders(count: rowCount), selectedIndex: 1)
        settle()
        XCTAssertEqual(scroll.contentView.bounds.origin.y, 0)

        model.present(rows: PanelViewModel.Row.placeholders(count: rowCount), selectedIndex: rowCount - 1)
        settle()
        XCTAssertTrue(isFullyVisible(rowCount - 1, in: scroll))
    }

    // MARK: Helpers

    private func settle() {
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.06))
    }

    private func scrollView(in view: NSView? = nil) -> NSScrollView? {
        let root = view ?? hosting
        if let scroll = root as? NSScrollView { return scroll }
        for child in root!.subviews {
            if let found = scrollView(in: child) { return found }
        }
        return nil
    }

    private func rowFrame(_ index: Int) -> ClosedRange<CGFloat> {
        let top = CGFloat(index) * (Theme.rowHeight + Theme.rowGap)
        return top...(top + Theme.rowHeight)
    }

    private func isFullyVisible(_ index: Int, in scroll: NSScrollView) -> Bool {
        let visible = scroll.contentView.bounds
        let row = rowFrame(index)
        return row.lowerBound >= visible.minY - 0.5 && row.upperBound <= visible.maxY + 0.5
    }

    private func lastVisibleRow(_ scroll: NSScrollView) -> Int {
        (0..<rowCount).last { isFullyVisible($0, in: scroll) } ?? -1
    }
}
