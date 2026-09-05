import AppKit
import XCTest
@testable import OpenTab

/// The General page's panel controls. Each one has to reach the geometry the
/// panel is actually built from, not a second copy of the same number.
@MainActor
final class PanelAppearanceTests: XCTestCase {
    override func tearDown() {
        Theme.apply(Theme.Style())
    }

    func testWidthIsTakenFromTheSameTokenTheFrameUses() {
        Theme.apply(Theme.Style(textScale: 1, isWide: false))
        XCTAssertEqual(PanelController.Metrics.width, 260)
        XCTAssertEqual(PanelController.Metrics.size(rowCount: 5, visibleHeight: nil).width, 260)

        Theme.apply(Theme.Style(textScale: 1, isWide: true))
        XCTAssertEqual(PanelController.Metrics.width, 300)
        XCTAssertEqual(PanelController.Metrics.size(rowCount: 5, visibleHeight: nil).width, 300)
    }

    /// Larger text must not need a taller row: the row is 46pt and the two
    /// lines at the largest scale have to still fit inside it.
    func testLargestTextStillFitsTheFixedRowHeight() {
        Theme.apply(Theme.Style(textScale: PanelTextSize.large.scale, isWide: false))
        let lines = (13.5 + 12) * PanelTextSize.large.scale + Theme.titleSubtitleGap
        XCTAssertLessThan(lines, Theme.rowHeight)
    }

    func testPositionsPutThePanelAgainstTheChosenEdge() throws {
        let screen = try XCTUnwrap(NSScreen.screens.first)
        let bounds = screen.visibleFrame
        let size = NSSize(width: 260, height: 400)

        let left = ScreenPlacement.frame(for: size, on: screen, position: .left)
        let centre = ScreenPlacement.frame(for: size, on: screen, position: .centre)
        let right = ScreenPlacement.frame(for: size, on: screen, position: .right)

        XCTAssertEqual(left.minX, bounds.minX + ScreenPlacement.edgeMargin, accuracy: 0.5)
        XCTAssertEqual(centre.midX, bounds.midX, accuracy: 0.5)
        XCTAssertEqual(right.maxX, bounds.maxX - ScreenPlacement.edgeMargin, accuracy: 0.5)
        for frame in [left, centre, right] {
            XCTAssertEqual(frame.midY, bounds.midY, accuracy: 0.5)
            XCTAssertGreaterThanOrEqual(frame.minX, bounds.minX)
            XCTAssertLessThanOrEqual(frame.maxX, bounds.maxX)
        }
    }

    /// A panel wider than the screen is clamped rather than pushed off it.
    func testAnOversizePanelStaysOnScreen() throws {
        let screen = try XCTUnwrap(NSScreen.screens.first)
        let bounds = screen.visibleFrame
        let size = NSSize(width: bounds.width + 200, height: bounds.height + 200)
        for position in PanelPosition.allCases {
            let frame = ScreenPlacement.frame(for: size, on: screen, position: position)
            XCTAssertEqual(frame.minX, bounds.minX, accuracy: 0.5)
            XCTAssertEqual(frame.minY, bounds.minY, accuracy: 0.5)
        }
    }

    /// The long-run memory check reads this; zero would mean the observation
    /// silently measures nothing.
    func testHealthSnapshotReportsARealFootprint() {
        let monitor = HealthMonitor()
        monitor.entryCount = { 42 }
        let snapshot = monitor.snapshot()
        XCTAssertGreaterThan(snapshot.footprintBytes, 1_000_000)
        XCTAssertGreaterThanOrEqual(snapshot.peakFootprintBytes, snapshot.footprintBytes)
        XCTAssertEqual(snapshot.entryCount, 42)
    }

    /// The About page shows this verbatim; the row count is not in it, because
    /// the General page already has its own row for that.
    func testHealthTextReadsAsASentence() {
        let hours = HealthMonitor.Snapshot(footprintBytes: 54_000_000, peakFootprintBytes: 59_700_000,
                                           entryCount: 42, uptime: .seconds(17_280))
        XCTAssertEqual(hours.text, "51.5 MB now, 56.9 MB peak \u{00B7} running 4.8 h")
        let minutes = HealthMonitor.Snapshot(footprintBytes: 54_000_000, peakFootprintBytes: 59_700_000,
                                             entryCount: 42, uptime: .seconds(2_220))
        XCTAssertEqual(minutes.text, "51.5 MB now, 56.9 MB peak \u{00B7} running 37 min")
    }
}
