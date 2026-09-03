import AppKit

enum ScreenPlacement {
    /// Distance from the usable edge of the screen for the left and right
    /// positions.
    static let edgeMargin: CGFloat = 24

    /// `NSScreen.main` follows the key window, which an agent app rarely has,
    /// so the screen under the cursor is the one the user is looking at.
    static func screenUnderMouse() -> NSScreen? {
        let screens = NSScreen.screens
        let point = NSEvent.mouseLocation
        return screens.first { $0.frame.contains(point) } ?? screens.first
    }

    /// Vertically centred on `visibleFrame`: the menu bar and Dock strips are
    /// asymmetric, so a panel centred on `frame` sits visibly low. The
    /// horizontal edge is the user's choice.
    static func frame(for size: NSSize, on screen: NSScreen, position: PanelPosition = .left) -> NSRect {
        let bounds = screen.visibleFrame
        let x: CGFloat
        switch position {
        case .left: x = bounds.minX + edgeMargin
        case .centre: x = bounds.midX - size.width / 2
        case .right: x = bounds.maxX - edgeMargin - size.width
        }
        var frame = NSRect(x: x, y: bounds.midY - size.height / 2, width: size.width, height: size.height)
        frame.origin.x = min(max(frame.origin.x, bounds.minX), max(bounds.minX, bounds.maxX - size.width))
        frame.origin.y = min(max(frame.origin.y, bounds.minY), max(bounds.minY, bounds.maxY - size.height))
        return frame
    }
}
