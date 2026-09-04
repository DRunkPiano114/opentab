import CryptoKit
import Foundation
import ImageIO
import SQLite3
import Synchronization

/// Cache identity for one site.
///
/// Everything downstream is keyed by `origin`; `page` only widens the chance of
/// a hit, because a browser cache usually has a row for the deep page the user
/// is actually on and sometimes only one for the site root.
struct FaviconKey: Hashable, Sendable {
    /// `scheme://host[:port]/`, always with the trailing slash.
    let origin: String
    /// The page URL as the browser would have stored it.
    let page: String
    let host: String

    init?(url: URL) {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return nil }
        guard let host = url.host(percentEncoded: false), !host.isEmpty else { return nil }
        var origin = "\(scheme)://\(host)"
        if let port = url.port, port != (scheme == "https" ? 443 : 80) {
            origin += ":\(port)"
        }
        origin += "/"
        self.origin = origin
        self.page = url.absoluteString
        self.host = host
    }
}

enum FaviconTier: Sendable {
    /// A browser's own on-disk cache, or our copy of what it once gave us.
    case browserCache
    case remote
}

struct FaviconLookupResult: Sendable {
    let origin: String
    /// Bytes of an image that already decoded once. Nil means "nothing found".
    let data: Data?
    let tier: FaviconTier?
}

/// A directory that contains Safari's `Favicon Cache`, plus whether reading it
/// has to be bracketed by security-scoped access.
struct FaviconSafariCache: Sendable {
    var directory: URL
    var securityScoped: Bool
}

/// Everything the lookup engine touches outside its own process, so tests can
/// point it at a temporary tree instead of the real `~/Library`.
struct FaviconConfiguration: Sendable {
    var chromiumUserDataDirectories: [URL]
    var safariCache: @Sendable () -> FaviconSafariCache?
    var diskCacheDirectory: URL
    var remoteFetch: @Sendable (URL) -> Data?

    static func production(defaults: UserDefaults = .standard) -> FaviconConfiguration {
        // UserDefaults is documented thread-safe but is not marked Sendable, and
        // the engine queue only ever reads the Safari bookmark through it.
        nonisolated(unsafe) let defaults = defaults
        return FaviconConfiguration(
            chromiumUserDataDirectories: FaviconChromiumSource.productionUserDataDirectories(),
            safariCache: { FaviconSafariBookmark.resolve(defaults: defaults) },
            diskCacheDirectory: FaviconDiskCache.productionDirectory,
            remoteFetch: FaviconRemoteSource.fetch)
    }
}

// MARK: - Engine

/// Runs every blocking lookup on one dedicated queue.
///
/// SQLite, `copyItem` and the remote fetch all block their thread for an
/// unbounded time; on the cooperative pool that would starve unrelated async
/// work, so none of this may live in an `actor`.
final class FaviconEngine: Sendable {
    private let configuration: FaviconConfiguration
    private let queue = DispatchQueue(label: "im.opentab.app.favicons", qos: .utility)

    init(configuration: FaviconConfiguration) {
        self.configuration = configuration
    }

    func lookup(keys: [FaviconKey],
                pixelSize: Int,
                allowRemote: Bool,
                completion: @escaping @Sendable @MainActor ([FaviconLookupResult]) -> Void) {
        queue.async {
            let results = self.resolve(keys: keys, pixelSize: pixelSize, allowRemote: allowRemote)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { completion(results) }
            }
        }
    }

    /// Forgets which sites were not found, so a source that just became
    /// available is consulted on the next prefetch.
    func purgeNegativeCache() {
        let directory = configuration.diskCacheDirectory
        queue.async { FaviconDiskCache(directory: directory).purgeMisses() }
    }

    /// Blocking variant, for the tests and for the diagnostic self test. Never
    /// call this from the main thread in the shipping app.
    func lookupBlocking(keys: [FaviconKey], pixelSize: Int, allowRemote: Bool) -> [FaviconLookupResult] {
        queue.sync { self.resolve(keys: keys, pixelSize: pixelSize, allowRemote: allowRemote) }
    }

    private func resolve(keys: [FaviconKey], pixelSize: Int, allowRemote: Bool) -> [FaviconLookupResult] {
        let cache = FaviconDiskCache(directory: configuration.diskCacheDirectory)
        var resolved: [String: FaviconLookupResult] = [:]
        var pending: [FaviconKey] = []
        var seen: Set<String> = []

        for key in keys where seen.insert(key.origin).inserted {
            switch cache.load(origin: key.origin) {
            case .hit(let data):
                resolved[key.origin] = FaviconLookupResult(origin: key.origin, data: data, tier: .browserCache)
            case .knownMiss:
                resolved[key.origin] = FaviconLookupResult(origin: key.origin, data: nil, tier: nil)
            case .unknown:
                pending.append(key)
            }
        }

        let takeHit: (FaviconKey, Data, FaviconTier) -> Void = { key, data, tier in
            cache.store(data, origin: key.origin)
            resolved[key.origin] = FaviconLookupResult(origin: key.origin, data: data, tier: tier)
        }

        for database in FaviconChromiumSource.profileDatabases(in: configuration.chromiumUserDataDirectories) {
            if pending.isEmpty { break }
            guard let snapshot = FaviconSnapshot(original: database) else { continue }
            defer { snapshot.discard() }
            guard let db = FaviconSQLite.openPrivateCopy(snapshot.database) else { continue }
            defer { FaviconSQLite.close(db) }
            pending = pending.filter { key in
                guard let data = FaviconChromiumSource.icon(db: db, key: key, pixelSize: pixelSize) else { return true }
                takeHit(key, data, .browserCache)
                return false
            }
        }

        if !pending.isEmpty, let safari = configuration.safariCache() {
            let scoped = safari.securityScoped && safari.directory.startAccessingSecurityScopedResource()
            defer { if scoped { safari.directory.stopAccessingSecurityScopedResource() } }
            if let cacheDirectory = FaviconSafariSource.cacheDirectory(in: safari.directory),
               let snapshot = FaviconSnapshot(original: cacheDirectory.appending(path: "favicons.db")) {
                defer { snapshot.discard() }
                if let db = FaviconSQLite.openPrivateCopy(snapshot.database) {
                    defer { FaviconSQLite.close(db) }
                    pending = pending.filter { key in
                        guard let data = FaviconSafariSource.icon(db: db, directory: cacheDirectory, key: key)
                        else { return true }
                        takeHit(key, data, .browserCache)
                        return false
                    }
                }
            }
        }

        if allowRemote {
            pending = pending.filter { key in
                guard let url = FaviconRemoteSource.endpoint(host: key.host, pixelSize: pixelSize),
                      let data = configuration.remoteFetch(url),
                      FaviconImageData.isDecodable(data)
                else { return true }
                takeHit(key, data, .remote)
                return false
            }
        }

        for key in pending {
            cache.recordMiss(origin: key.origin)
            resolved[key.origin] = FaviconLookupResult(origin: key.origin, data: nil, tier: nil)
        }
        return Array(resolved.values)
    }
}

// MARK: - Chromium

enum FaviconChromiumSource {
    /// Chromium-family user-data directories under `~/Library/Application Support`.
    /// Every entry is probed for existence; profiles are then enumerated, so a
    /// user with `Profile 3` is not silently limited to `Default`.
    static let userDataRelativePaths = [
        "Google/Chrome",
        "Google/Chrome Beta",
        "Google/Chrome Dev",
        "Google/Chrome Canary",
        "Chromium",
        "BraveSoftware/Brave-Browser",
        "BraveSoftware/Brave-Browser-Beta",
        "BraveSoftware/Brave-Browser-Nightly",
        "Microsoft Edge",
        "Microsoft Edge Beta",
        "Microsoft Edge Dev",
        "Microsoft Edge Canary",
        "Vivaldi",
        "Arc/User Data",
    ]

    static func productionUserDataDirectories() -> [URL] {
        let support = URL(fileURLWithPath: NSHomeDirectory()).appending(path: "Library/Application Support")
        return userDataRelativePaths
            .map { support.appending(path: $0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// Every `<userData>/<profile>/Favicons` that exists, most recently written
    /// first so the browser the user actually uses is consulted before the
    /// stale ones and the loop can stop early.
    static func profileDatabases(in userDataDirectories: [URL]) -> [URL] {
        let fm = FileManager.default
        var found: [(url: URL, modified: Date)] = []
        for root in userDataDirectories {
            let profiles = (try? fm.contentsOfDirectory(at: root,
                                                        includingPropertiesForKeys: [.isDirectoryKey],
                                                        options: [.skipsHiddenFiles])) ?? []
            for profile in profiles {
                let database = profile.appending(path: "Favicons")
                guard let attributes = try? fm.attributesOfItem(atPath: database.path),
                      attributes[.type] as? FileAttributeType == .typeRegular
                else { continue }
                found.append((database, attributes[.modificationDate] as? Date ?? .distantPast))
            }
        }
        return found.sorted { $0.modified > $1.modified }.map(\.url)
    }

    /// Exact page URL first, then the site root, because a deep page often has
    /// no `icon_mapping` row of its own.
    static func icon(db: OpaquePointer, key: FaviconKey, pixelSize: Int) -> Data? {
        for candidate in [key.page, key.origin] {
            let bitmaps = bitmaps(db: db, pageURL: candidate)
            if let data = select(bitmaps, pixelSize: pixelSize) { return data }
        }
        return nil
    }

    private static let bitmapSQL = """
        SELECT b.width, b.image_data \
        FROM icon_mapping m JOIN favicon_bitmaps b ON b.icon_id = m.icon_id \
        WHERE m.page_url = ?
        """

    private static func bitmaps(db: OpaquePointer, pageURL: String) -> [(width: Int, data: Data)] {
        var rows: [(width: Int, data: Data)] = []
        FaviconSQLite.query(db: db, sql: bitmapSQL, text: pageURL) { statement in
            let width = Int(sqlite3_column_int(statement, 0))
            guard let bytes = sqlite3_column_blob(statement, 1) else { return }
            let count = Int(sqlite3_column_bytes(statement, 1))
            guard count > 0 else { return }
            rows.append((width, Data(bytes: bytes, count: count)))
        }
        return rows
    }

    /// Best fit: the smallest bitmap that still covers the target, else the
    /// largest one there is. Undecodable rows are skipped rather than returned.
    private static func select(_ rows: [(width: Int, data: Data)], pixelSize: Int) -> Data? {
        let usable = rows.filter { FaviconImageData.isDecodable($0.data) }
        guard !usable.isEmpty else { return nil }
        let covering = usable.filter { $0.width >= pixelSize }
        if let best = covering.min(by: { $0.width < $1.width }) { return best.data }
        return usable.max(by: { $0.width < $1.width })?.data
    }
}

// MARK: - Safari

enum FaviconSafariSource {
    /// The bookmark normally points at `~/Library/Safari`, but a user who
    /// drilled down in the open panel can hand us the cache directory itself.
    static func cacheDirectory(in directory: URL) -> URL? {
        let nested = directory.appending(path: "Favicon Cache")
        if FileManager.default.fileExists(atPath: nested.appending(path: "favicons.db").path) { return nested }
        if FileManager.default.fileExists(atPath: directory.appending(path: "favicons.db").path) { return directory }
        return nil
    }

    static func icon(db: OpaquePointer, directory: URL, key: FaviconKey) -> Data? {
        for candidate in matchCandidates(for: key) {
            guard let uuid = uuid(db: db, url: candidate) else { continue }
            guard let data = try? Data(contentsOf: imageURL(directory: directory, uuid: uuid)) else { continue }
            // SVG payloads are stored here too and CGImageSource cannot read
            // them; that is a miss, not a failure.
            if FaviconImageData.isDecodable(data) { return data }
        }
        return nil
    }

    /// `page_url.url` is stored with the trailing slash stripped, so a URL that
    /// carries one never matches unless it is normalised first.
    static func matchCandidates(for key: FaviconKey) -> [String] {
        var candidates: [String] = []
        for value in [key.page, key.origin] {
            let trimmed = value.hasSuffix("/") ? String(value.dropLast()) : value
            for form in [trimmed, value] where !form.isEmpty && !candidates.contains(form) {
                candidates.append(form)
            }
        }
        return candidates
    }

    /// `MD5(uuid)` as uppercase hex, no extension.
    static func imageURL(directory: URL, uuid: String) -> URL {
        let digest = Insecure.MD5.hash(data: Data(uuid.utf8))
        let name = digest.map { String(format: "%02X", $0) }.joined()
        return directory.appending(path: "favicons").appending(path: name)
    }

    private static func uuid(db: OpaquePointer, url: String) -> String? {
        var found: String?
        FaviconSQLite.query(db: db, sql: "SELECT uuid FROM page_url WHERE url = ? LIMIT 1", text: url) { statement in
            guard found == nil, let text = sqlite3_column_text(statement, 0) else { return }
            found = String(cString: text)
        }
        return found
    }
}

/// Reads and writes the security-scoped bookmark that stands in for Full Disk
/// Access on Safari's TCC-protected cache.
enum FaviconSafariBookmark {
    static let defaultsKey = "favicons.safariBookmark"

    static func resolve(defaults: UserDefaults) -> FaviconSafariCache? {
        guard let data = defaults.data(forKey: defaultsKey) else { return nil }
        var stale = false
        if let url = try? URL(resolvingBookmarkData: data,
                              options: [.withSecurityScope],
                              relativeTo: nil,
                              bookmarkDataIsStale: &stale) {
            return FaviconSafariCache(directory: url, securityScoped: true)
        }
        if let url = try? URL(resolvingBookmarkData: data,
                              options: [],
                              relativeTo: nil,
                              bookmarkDataIsStale: &stale) {
            return FaviconSafariCache(directory: url, securityScoped: false)
        }
        return nil
    }

    @discardableResult
    static func store(_ url: URL, defaults: UserDefaults) -> Bool {
        let data = (try? url.bookmarkData(options: [.withSecurityScope],
                                          includingResourceValuesForKeys: nil,
                                          relativeTo: nil))
            ?? (try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil))
        guard let data else { return false }
        defaults.set(data, forKey: defaultsKey)
        return true
    }
}

// MARK: - Remote

enum FaviconRemoteSource {
    static func endpoint(host: String, pixelSize: Int) -> URL? {
        var components = URLComponents(string: "https://www.google.com/s2/favicons")
        components?.queryItems = [
            URLQueryItem(name: "domain", value: host),
            URLQueryItem(name: "sz", value: String(max(16, pixelSize))),
        ]
        return components?.url
    }

    /// Synchronous by design: it only ever runs on the engine's dedicated
    /// queue, which exists precisely to absorb blocking calls.
    static let fetch: @Sendable (URL) -> Data? = { url in
        let box = FaviconDataBox()
        let semaphore = DispatchSemaphore(value: 0)
        let request = URLRequest(url: url, cachePolicy: .returnCacheDataElseLoad, timeoutInterval: 5)
        URLSession.shared.dataTask(with: request) { data, response, _ in
            if let http = response as? HTTPURLResponse, http.statusCode == 200, let data, !data.isEmpty {
                box.value = data
            }
            semaphore.signal()
        }.resume()
        guard semaphore.wait(timeout: .now() + 6) == .success else { return nil }
        return box.value
    }
}

/// One `Data?` handed from a URLSession callback thread back to the caller.
private final class FaviconDataBox: Sendable {
    private let storage = Mutex<Data?>(nil)

    var value: Data? {
        get { storage.withLock { $0 } }
        set { storage.withLock { $0 = newValue } }
    }
}

// MARK: - Image gate

enum FaviconImageData {
    /// True when ImageIO can actually turn these bytes into an image. Applied
    /// before anything is cached, so a corrupt or SVG payload degrades to a
    /// miss instead of a blank row.
    static func isDecodable(_ data: Data) -> Bool {
        guard !data.isEmpty,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0,
              CGImageSourceCreateImageAtIndex(source, 0, nil) != nil
        else { return false }
        return true
    }
}
