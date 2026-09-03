import AppKit
import Foundation
import OpenTabCore

/// Favicons for the tab detail rows, resolved from the browsers' own on-disk
/// caches and rasterised once per (origin, point size).
///
/// Three tiers, and the network is not one of them by default:
///
/// 1. A Chromium profile's `Favicons` database, or Safari's `Favicon Cache`.
/// 2. Nothing — `icon(for:pointSize:)` answers nil and the row draws the app
///    icon. Every failure below (missing file, locked database, corrupt bytes,
///    revoked bookmark) lands here quietly.
/// 3. Google's `s2/favicons`, only when the user has explicitly turned it on.
///
/// All file and SQLite work happens on `FaviconEngine`'s dedicated queue; this
/// class only holds main-actor state and does the drawing (iron law L13).
@MainActor
final class FaviconStore {
    static let shared = FaviconStore()

    struct HitStats: Sendable {
        /// Served from a browser's cache, or from our copy of what one gave us.
        var browserCache = 0
        /// Served by a live remote fetch.
        var remote = 0
        var missed = 0
    }

    static let remoteDisclosureText =
        "Looking up icons online sends the domain of every tab you have open to Google, one by one."

    static let remoteLookupDefaultsKey = "favicons.allowRemoteLookup"

    /// What the bitmap chooser aims at and what the remote tier asks for. The
    /// detail row draws a 28pt icon, and 2x covers every current display.
    private static let targetPixelSize = 64
    private let scale: CGFloat = 2

    private struct RasterKey: Hashable {
        let origin: String
        let pointSize: CGFloat
    }

    private let engine: FaviconEngine
    private let defaults: UserDefaults
    private let log = Log.make("favicon")

    private var sources: [String: NSImage] = [:]
    private var rasters: [RasterKey: NSImage] = [:]
    private var misses: Set<String> = []
    private var inFlight: Set<String> = []
    private var batches: [Int: @MainActor () -> Void] = [:]
    private var nextBatch = 0

    private(set) var stats = HitStats()

    init(configuration: FaviconConfiguration? = nil, defaults: UserDefaults = .standard) {
        self.engine = FaviconEngine(configuration: configuration ?? .production(defaults: defaults))
        self.defaults = defaults
    }

    // MARK: Drawing

    /// Rasterised to `pointSize` for the detail row. Nil while nothing is known
    /// yet and nil when nothing was found; the caller draws the app icon.
    ///
    /// Deliberately free of side effects: the draw path never starts a lookup.
    func icon(for url: URL?, pointSize: CGFloat) -> NSImage? {
        guard let url, let key = FaviconKey(url: url) else { return nil }
        let rasterKey = RasterKey(origin: key.origin, pointSize: pointSize)
        if let hit = rasters[rasterKey] { return hit }
        guard let source = sources[key.origin] else { return nil }
        let raster = Self.rasterise(source, pointSize: pointSize, scale: scale)
        rasters[rasterKey] = raster
        return raster
    }

    // MARK: Lookup

    /// Starts lookups for the URLs that are not cached yet. `onUpdate` fires
    /// once, on the main actor, when this batch lands. Nothing is scheduled and
    /// `onUpdate` never fires when every URL is already known.
    func prefetch(_ urls: [URL], onUpdate: @escaping @MainActor () -> Void) {
        var keys: [FaviconKey] = []
        var origins: Set<String> = []
        for url in urls {
            guard let key = FaviconKey(url: url) else { continue }
            guard sources[key.origin] == nil, !misses.contains(key.origin), !inFlight.contains(key.origin) else { continue }
            guard origins.insert(key.origin).inserted else { continue }
            keys.append(key)
        }
        guard !keys.isEmpty else { return }

        inFlight.formUnion(origins)
        nextBatch += 1
        let batch = nextBatch
        batches[batch] = onUpdate

        engine.lookup(keys: keys,
                      pixelSize: Self.targetPixelSize,
                      allowRemote: isRemoteLookupEnabled) { [weak self] results in
            self?.absorb(results, batch: batch)
        }
    }

    private func absorb(_ results: [FaviconLookupResult], batch: Int) {
        var found = 0
        var missed = 0
        for result in results {
            inFlight.remove(result.origin)
            guard let data = result.data, let image = NSImage(data: data) else {
                misses.insert(result.origin)
                stats.missed += 1
                missed += 1
                continue
            }
            sources[result.origin] = image
            found += 1
            switch result.tier {
            case .remote: stats.remote += 1
            case .browserCache, nil: stats.browserCache += 1
            }
        }
        // Counts only: no URL, host or title ever reaches the log (iron law L16).
        log.debug("favicon batch found=\(found, privacy: .public) missed=\(missed, privacy: .public)")
        let callback = batches.removeValue(forKey: batch)
        callback?()
    }

    // MARK: Remote opt-in

    /// Off unless the user turned it on. See `remoteDisclosureText`.
    var isRemoteLookupEnabled: Bool {
        get { defaults.bool(forKey: Self.remoteLookupDefaultsKey) }
        set {
            defaults.set(newValue, forKey: Self.remoteLookupDefaultsKey)
            if newValue { forgetMisses() }
        }
    }

    /// A site that missed while a tier was unavailable deserves another chance
    /// once that tier exists, rather than waiting out the negative cache.
    private func forgetMisses() {
        misses.removeAll()
        engine.purgeNegativeCache()
    }

    // MARK: Safari access

    /// Safari's favicon cache is TCC-protected. Rather than asking for Full Disk
    /// Access, let the user hand us `~/Library/Safari` once through an open
    /// panel and keep the security-scoped bookmark.
    ///
    /// Presents a modal panel, so call it from a menu item with the app active.
    @discardableResult
    func requestSafariCacheAccess() -> Bool {
        let panel = NSOpenPanel()
        panel.message = "Choose your Safari folder so OpenTab can read its favicon cache."
        panel.prompt = "Grant Access"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.directoryURL = URL(fileURLWithPath: NSHomeDirectory()).appending(path: "Library/Safari")
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        let granted = FaviconSafariBookmark.store(url, defaults: defaults)
        if granted { forgetMisses() }
        return granted
    }

    /// Whether a bookmark is stored. The bookmark can still fail to resolve
    /// later; that degrades to a miss rather than an error.
    var hasSafariCacheAccess: Bool {
        defaults.data(forKey: FaviconSafariBookmark.defaultsKey) != nil
    }

    // MARK: Rasterisation

    /// Flattened into one `NSBitmapImageRep` at 2x so the row never pays a
    /// decode or a resample while drawing, matching `IconCache`.
    private static func rasterise(_ image: NSImage, pointSize: CGFloat, scale: CGFloat) -> NSImage {
        let px = Int(pointSize * scale)
        guard px > 0, let rep = NSBitmapImageRep(
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
        image.draw(in: fit(image.size, into: pointSize))
        NSGraphicsContext.restoreGraphicsState()

        let out = NSImage(size: NSSize(width: pointSize, height: pointSize))
        out.addRepresentation(rep)
        return out
    }

    /// Favicons are square in practice, but a non-square one must not stretch.
    private static func fit(_ size: NSSize, into pointSize: CGFloat) -> NSRect {
        let square = NSRect(x: 0, y: 0, width: pointSize, height: pointSize)
        guard size.width > 0, size.height > 0, size.width != size.height else { return square }
        let side = pointSize * min(1, min(size.width, size.height) / max(size.width, size.height))
        let width = size.width > size.height ? pointSize : side
        let height = size.width > size.height ? side : pointSize
        return NSRect(x: (pointSize - width) / 2, y: (pointSize - height) / 2, width: width, height: height)
    }
}
