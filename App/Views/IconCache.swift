import AppKit
import OpenTabCore

/// App icons keyed by bundle path, pre-rasterised once to the exact pixel size
/// the row draws at.
///
/// `NSWorkspace.icon(forFile:)` returns a lazy multi-representation handle; the
/// decode happens on the first *draw*, which would otherwise land on the
/// panel-show path. Rasterising into a flat `NSBitmapImageRep` at launch moves
/// that cost off the critical path and avoids the non-integral 64px -> 56px
/// resample AppKit would pick for a 28pt icon on a 2x display.
@MainActor
final class IconCache {
    static let shared = IconCache()

    private var cache: [String: NSImage] = [:]
    private let pointSize: CGFloat = Theme.iconSize
    /// Render for Retina; 1x displays downsample cleanly.
    private let scale: CGFloat = 2

    /// Nil when no bundle path can be resolved for the app.
    func icon(for app: AppInfo) -> NSImage? {
        guard let path = Self.bundlePath(for: app) else { return nil }
        if let hit = cache[path] { return hit }
        let raster = Self.rasterise(NSWorkspace.shared.icon(forFile: path),
                                    pointSize: pointSize, scale: scale)
        cache[path] = raster
        return raster
    }

    /// Warm the cache off the critical path. Call at launch and when the running
    /// app list changes, never from the panel-show path.
    func prewarm(apps: [AppInfo]) {
        for app in apps { _ = icon(for: app) }
    }

    private static func bundlePath(for app: AppInfo) -> String? {
        if let url = NSRunningApplication(processIdentifier: app.pid)?.bundleURL {
            return url.path
        }
        guard !app.bundleID.isEmpty else { return nil }
        return NSWorkspace.shared.urlForApplication(withBundleIdentifier: app.bundleID)?.path
    }

    private static func rasterise(_ image: NSImage, pointSize: CGFloat, scale: CGFloat) -> NSImage {
        let px = Int(pointSize * scale)
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { return image }

        // Declaring the point size on a larger pixel buffer is what makes the
        // representation @2x.
        rep.size = NSSize(width: pointSize, height: pointSize)

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(in: NSRect(x: 0, y: 0, width: pointSize, height: pointSize))
        NSGraphicsContext.restoreGraphicsState()

        let out = NSImage(size: NSSize(width: pointSize, height: pointSize))
        out.addRepresentation(rep)
        return out
    }
}
