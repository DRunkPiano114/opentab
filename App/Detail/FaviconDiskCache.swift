import CryptoKit
import Foundation

/// Bytes we already found, plus markers for sites we already failed to find.
///
/// Without the negative marker every panel open would re-copy and re-query
/// every browser database for the same handful of sites that simply have no
/// cached icon. File names are SHA-256 of the origin: nothing on disk names a
/// host.
struct FaviconDiskCache: Sendable {
    enum Entry {
        case hit(Data)
        case knownMiss
        case unknown
    }

    /// A miss is only remembered for a day, so a site whose icon the browser
    /// caches tomorrow is not invisible forever.
    static let missLifetime: TimeInterval = 24 * 60 * 60

    /// Keyed by bundle id so a Debug build and the installed release never
    /// share (and never corrupt) one cache directory.
    static var productionDirectory: URL {
        let bundleID = Bundle.main.bundleIdentifier ?? "im.opentab.app"
        return URL(fileURLWithPath: NSHomeDirectory()).appending(path: "Library/Caches/\(bundleID)/favicons")
    }

    let directory: URL

    func load(origin: String) -> Entry {
        let base = name(for: origin)
        let icon = directory.appending(path: base)
        if let data = try? Data(contentsOf: icon), !data.isEmpty {
            return .hit(data)
        }
        let marker = directory.appending(path: base + ".miss")
        guard let modified = try? FileManager.default
            .attributesOfItem(atPath: marker.path)[.modificationDate] as? Date
        else { return .unknown }
        if Date().timeIntervalSince(modified) < Self.missLifetime {
            return .knownMiss
        }
        try? FileManager.default.removeItem(at: marker)
        return .unknown
    }

    func store(_ data: Data, origin: String) {
        guard createDirectory() else { return }
        let base = name(for: origin)
        try? data.write(to: directory.appending(path: base), options: .atomic)
        try? FileManager.default.removeItem(at: directory.appending(path: base + ".miss"))
    }

    func recordMiss(origin: String) {
        guard createDirectory() else { return }
        let marker = directory.appending(path: name(for: origin) + ".miss")
        try? Data().write(to: marker, options: .atomic)
        // An overwritten empty file keeps its old mtime on some filesystems.
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: marker.path)
    }

    /// Drops every negative marker. Needed when a new source becomes available,
    /// otherwise a site that missed an hour ago stays invisible for a day after
    /// the user grants Safari access or turns the remote tier on.
    func purgeMisses() {
        let fm = FileManager.default
        let names = (try? fm.contentsOfDirectory(atPath: directory.path)) ?? []
        for name in names where name.hasSuffix(".miss") {
            try? fm.removeItem(at: directory.appending(path: name))
        }
    }

    private func createDirectory() -> Bool {
        (try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)) != nil
    }

    private func name(for origin: String) -> String {
        SHA256.hash(data: Data(origin.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
