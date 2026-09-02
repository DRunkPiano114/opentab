import AppKit

enum ScreenPlacement {
    static let leftMargin: CGFloat = 24

    /// `NSScreen.main` follows the key window, which an agent app rarely has,
    /// so the screen under the cursor is the one the user is looking at.
    static func screenUnderMouse() -> NSScreen? {
        let screens = NSScreen.screens
        let point = NSEvent.mouseLocation
        return screens.first { $0.frame.contains(point) } ?? screens.first
    }

    /// Anchored to the left edge of the usable area and centred on
    /// `visibleFrame`: the menu bar and Dock strips are asymmetric, so a panel
    /// centred on `frame` sits visibly low.
    static func frame(for size: NSSize, on screen: NSScreen) -> NSRect {
        let bounds = screen.visibleFrame
        var frame = NSRect(x: bounds.minX + leftMargin,
                           y: bounds.midY - size.height / 2,
                           width: size.width, height: size.height)
        frame.origin.x = min(max(frame.origin.x, bounds.minX), max(bounds.minX, bounds.maxX - size.width))
        frame.origin.y = min(max(frame.origin.y, bounds.minY), max(bounds.minY, bounds.maxY - size.height))
        return frame
    }
}
