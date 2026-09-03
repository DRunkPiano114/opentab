import AppKit
import CryptoKit
import ImageIO
import SQLite3
import Synchronization
import XCTest

@testable import OpenTab

/// Every fixture is built in a temporary directory, so nothing here depends on
/// which browsers are installed, on `~/Library`, or on the network.
@MainActor
final class FaviconStoreTests: XCTestCase {
    private var root: URL!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appending(path: "favicon-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let root { try? FileManager.default.removeItem(at: root) }
        root = nil
    }

    // MARK: Chromium

    func testChromiumFindsTheRowForTheExactPageURL() throws {
        let userData = try makeChromiumProfile(rows: [
            ("https://example.com/deep/page", [32]),
            ("https://elsewhere.example/", [32]),
        ])
        let data = try XCTUnwrap(firstHit(chromium: [userData], page: "https://example.com/deep/page"))
        XCTAssertEqual(try pixelWidth(of: data), 32)
    }

    func testChromiumFallsBackToTheOriginRowWhenThePageHasNoMapping() throws {
        let userData = try makeChromiumProfile(rows: [("https://example.com/", [32])])
        XCTAssertNotNil(firstHit(chromium: [userData], page: "https://example.com/deep/page?q=1"))
    }

    func testChromiumPicksTheSmallestBitmapThatCoversTheTarget() throws {
        let userData = try makeChromiumProfile(rows: [("https://example.com/", [16, 32, 64])])
        let covering = try XCTUnwrap(firstHit(chromium: [userData], page: "https://example.com/", pixelSize: 32))
        XCTAssertEqual(try pixelWidth(of: covering), 32)
    }

    func testChromiumFallsBackToTheLargestBitmapWhenNoneCoversTheTarget() throws {
        let userData = try makeChromiumProfile(rows: [("https://example.com/", [16, 32, 64])])
        let largest = try XCTUnwrap(firstHit(chromium: [userData], page: "https://example.com/", pixelSize: 512))
        XCTAssertEqual(try pixelWidth(of: largest), 64)
    }

    func testMissingDatabaseYieldsNil() throws {
        let userData = root.appending(path: "Chrome")
        try FileManager.default.createDirectory(at: userData.appending(path: "Default"), withIntermediateDirectories: true)
        XCTAssertNil(firstHit(chromium: [userData, root.appending(path: "does-not-exist")],
                              page: "https://example.com/"))
    }

    func testTruncatedDatabaseYieldsNil() throws {
        let userData = try makeChromiumProfile(rows: [("https://example.com/", [32])])
        let database = userData.appending(path: "Default/Favicons")
        let head = try Data(contentsOf: database).prefix(120)
        try Data(head).write(to: database)
        XCTAssertNil(firstHit(chromium: [userData], page: "https://example.com/"))
    }

    func testGarbageInPlaceOfADatabaseYieldsNil() throws {
        let profile = root.appending(path: "Chrome/Default")
        try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
        try Data("this is not a database".utf8).write(to: profile.appending(path: "Favicons"))
        XCTAssertNil(firstHit(chromium: [root.appending(path: "Chrome")], page: "https://example.com/"))
    }

    func testUndecodableBitmapBytesYieldNil() throws {
        let userData = try makeChromiumProfile(rows: [])
        try addIcon(inProfileOf: userData, page: "https://example.com/", iconID: 1,
                    data: Data("<svg xmlns='http://www.w3.org/2000/svg'/>".utf8), width: 32)
        XCTAssertNil(firstHit(chromium: [userData], page: "https://example.com/"))
    }

    // MARK: Safari

    func testSafariImageFileNameIsUppercaseMD5OfTheUUID() {
        // MD5("abc"), a published test vector rather than a second call to the
        // same hash the implementation uses.
        let url = FaviconSafariSource.imageURL(directory: root, uuid: "abc")
        XCTAssertEqual(url.lastPathComponent, "900150983CD24FB0D6963F7D28E17F72")
    }

    func testSafariMatchesAStoredURLThatLostItsTrailingSlash() throws {
        let safari = try makeSafariCache(entries: [("https://example.com", "abc", try png(size: 32))])
        let data = try XCTUnwrap(firstHit(safari: safari, page: "https://example.com/"))
        XCTAssertEqual(try pixelWidth(of: data), 32)
    }

    func testSafariFallsBackFromADeepPageToTheOrigin() throws {
        let safari = try makeSafariCache(entries: [("https://example.com", "abc", try png(size: 32))])
        XCTAssertNotNil(firstHit(safari: safari, page: "https://example.com/deep/page"))
    }

    func testSafariBytesThatAreNotADecodableImageYieldNil() throws {
        let safari = try makeSafariCache(entries: [("https://example.com", "abc", Data("<svg xmlns=''/>".utf8))])
        XCTAssertNil(firstHit(safari: safari, page: "https://example.com/"))
    }

    func testSafariMissingImageFileYieldsNil() throws {
        let safari = try makeSafariCache(entries: [("https://example.com", "abc", try png(size: 32))])
        try FileManager.default.removeItem(at: FaviconSafariSource.imageURL(
            directory: safari.directory.appending(path: "Favicon Cache"), uuid: "abc"))
        XCTAssertNil(firstHit(safari: safari, page: "https://example.com/"))
    }

    // MARK: Remote tier

    func testRemoteIsNeverContactedWhileDisabled() throws {
        let calls = CallCounter()
        let engine = FaviconEngine(configuration: configuration(remote: { _ in
            calls.increment()
            return nil
        }))
        XCTAssertNil(hit(from: engine, page: "https://example.com/", allowRemote: false))
        XCTAssertEqual(calls.count, 0)
    }

    func testRemoteIsContactedOnlyOnceOptedIn() throws {
        let calls = CallCounter()
        let bytes = try png(size: 64)
        let engine = FaviconEngine(configuration: configuration(remote: { _ in
            calls.increment()
            return bytes
        }))
        XCTAssertNotNil(hit(from: engine, page: "https://example.com/", allowRemote: true))
        XCTAssertEqual(calls.count, 1)
    }

    func testRemoteEndpointCarriesOnlyTheHostAndSize() throws {
        let url = try XCTUnwrap(FaviconRemoteSource.endpoint(host: "example.com", pixelSize: 64))
        XCTAssertEqual(url.absoluteString, "https://www.google.com/s2/favicons?domain=example.com&sz=64")
    }

    // MARK: Disk cache

    func testNegativeCacheStopsASecondLookupFromReadingTheDatabaseAgain() throws {
        let userData = try makeChromiumProfile(rows: [("https://elsewhere.example/", [32])])
        let cache = root.appending(path: "cache")
        let first = FaviconEngine(configuration: configuration(chromium: [userData], cache: cache))
        XCTAssertNil(hit(from: first, page: "https://example.com/"))

        // The row the first pass could not find now exists. A fresh engine over
        // the same disk cache must still answer nil, which it can only do by
        // trusting the negative marker instead of reopening the database.
        try addIcon(inProfileOf: userData, page: "https://example.com/", iconID: 99,
                    data: try png(size: 32), width: 32)
        let second = FaviconEngine(configuration: configuration(chromium: [userData], cache: cache))
        XCTAssertNil(hit(from: second, page: "https://example.com/"))
    }

    func testPositiveDiskCacheServesAfterTheBrowserDatabaseIsGone() throws {
        let userData = try makeChromiumProfile(rows: [("https://example.com/", [32])])
        let cache = root.appending(path: "cache")
        let first = FaviconEngine(configuration: configuration(chromium: [userData], cache: cache))
        XCTAssertNotNil(hit(from: first, page: "https://example.com/"))

        try FileManager.default.removeItem(at: userData)
        let second = FaviconEngine(configuration: configuration(chromium: [userData], cache: cache))
        XCTAssertNotNil(hit(from: second, page: "https://example.com/"))
    }

    func testPurgingNegativeMarkersLetsANewSourceBeConsultedAgain() throws {
        let userData = try makeChromiumProfile(rows: [])
        let cache = root.appending(path: "cache")
        let engine = FaviconEngine(configuration: configuration(chromium: [userData], cache: cache))
        XCTAssertNil(hit(from: engine, page: "https://example.com/"))

        try addIcon(inProfileOf: userData, page: "https://example.com/", iconID: 1,
                    data: try png(size: 32), width: 32)
        FaviconDiskCache(directory: cache).purgeMisses()
        XCTAssertNotNil(hit(from: engine, page: "https://example.com/"))
    }

    func testDiskCacheNamesNothingAfterTheHost() throws {
        let cache = FaviconDiskCache(directory: root.appending(path: "cache"))
        cache.recordMiss(origin: "https://secret.example/")
        let names = try FileManager.default.contentsOfDirectory(atPath: root.appending(path: "cache").path)
        XCTAssertEqual(names.count, 1)
        XCTAssertFalse(try XCTUnwrap(names.first).contains("secret"))
    }

    // MARK: Key normalisation

    func testKeyRejectsSchemesThatHaveNoFavicon() throws {
        XCTAssertNil(FaviconKey(url: URL(fileURLWithPath: "/tmp/page.html")))
        XCTAssertNil(FaviconKey(url: try XCTUnwrap(URL(string: "chrome://settings"))))
    }

    func testKeyKeepsANonDefaultPortOutOfTheOrigin() throws {
        let plain = try XCTUnwrap(FaviconKey(url: try XCTUnwrap(URL(string: "https://example.com:443/x"))))
        XCTAssertEqual(plain.origin, "https://example.com/")
        let ported = try XCTUnwrap(FaviconKey(url: try XCTUnwrap(URL(string: "http://example.com:8080/x"))))
        XCTAssertEqual(ported.origin, "http://example.com:8080/")
    }

    // MARK: Store

    func testStoreRasterisesToThePointSizeAndCountsTheHit() throws {
        let userData = try makeChromiumProfile(rows: [("https://example.com/", [64])])
        let store = FaviconStore(configuration: configuration(chromium: [userData]),
                                 defaults: try makeDefaults())
        let url = try XCTUnwrap(URL(string: "https://example.com/deep/page"))
        XCTAssertNil(store.icon(for: url, pointSize: 28))

        let landed = expectation(description: "batch landed")
        store.prefetch([url]) { landed.fulfill() }
        wait(for: [landed], timeout: 5)

        let icon = try XCTUnwrap(store.icon(for: url, pointSize: 28))
        XCTAssertEqual(icon.size, NSSize(width: 28, height: 28))
        let rep = try XCTUnwrap(icon.representations.first)
        XCTAssertEqual(rep.pixelsWide, 56)
        XCTAssertEqual(store.stats.browserCache, 1)
        XCTAssertEqual(store.stats.missed, 0)
    }

    func testStoreAnswersNilForURLsItCannotServe() throws {
        let store = FaviconStore(configuration: configuration(), defaults: try makeDefaults())
        XCTAssertNil(store.icon(for: nil, pointSize: 28))
        XCTAssertNil(store.icon(for: URL(fileURLWithPath: "/tmp/x.html"), pointSize: 28))
    }

    func testStorePrefetchSchedulesNothingWhenThereIsNothingToLookUp() throws {
        let store = FaviconStore(configuration: configuration(), defaults: try makeDefaults())
        let notCalled = expectation(description: "onUpdate not called")
        notCalled.isInverted = true
        store.prefetch([URL(fileURLWithPath: "/tmp/x.html")]) { notCalled.fulfill() }
        wait(for: [notCalled], timeout: 0.3)
    }

    func testStoreRemoteLookupIsOffByDefault() throws {
        let store = FaviconStore(configuration: configuration(), defaults: try makeDefaults())
        XCTAssertFalse(store.isRemoteLookupEnabled)
        store.isRemoteLookupEnabled = true
        XCTAssertTrue(store.isRemoteLookupEnabled)
        XCTAssertTrue(FaviconStore.remoteDisclosureText.lowercased().contains("google"))
    }

    func testStoreReportsNoSafariAccessWithoutABookmark() throws {
        let store = FaviconStore(configuration: configuration(), defaults: try makeDefaults())
        XCTAssertFalse(store.hasSafariCacheAccess)
    }

    // MARK: - Fixtures

    private func configuration(chromium: [URL] = [],
                               safari: FaviconSafariCache? = nil,
                               cache: URL? = nil,
                               remote: @escaping @Sendable (URL) -> Data? = { _ in nil }) -> FaviconConfiguration {
        let cacheDirectory = cache ?? root.appending(path: "cache-\(UUID().uuidString)")
        return FaviconConfiguration(chromiumUserDataDirectories: chromium,
                                    safariCache: { safari },
                                    diskCacheDirectory: cacheDirectory,
                                    remoteFetch: remote)
    }

    private func makeDefaults() throws -> UserDefaults {
        try XCTUnwrap(UserDefaults(suiteName: "favicon-tests-\(UUID().uuidString)"))
    }

    private func firstHit(chromium: [URL] = [],
                          safari: FaviconSafariCache? = nil,
                          page: String,
                          pixelSize: Int = 64) -> Data? {
        let engine = FaviconEngine(configuration: configuration(chromium: chromium, safari: safari))
        return hit(from: engine, page: page, pixelSize: pixelSize)
    }

    private func hit(from engine: FaviconEngine,
                     page: String,
                     pixelSize: Int = 64,
                     allowRemote: Bool = false) -> Data? {
        guard let url = URL(string: page), let key = FaviconKey(url: url) else { return nil }
        return engine.lookupBlocking(keys: [key], pixelSize: pixelSize, allowRemote: allowRemote).first?.data
    }

    /// `<root>/<name>/Default/Favicons` with Chromium's real schema.
    private func makeChromiumProfile(name: String = "Chrome",
                                     rows: [(page: String, sizes: [Int])]) throws -> URL {
        let userData = root.appending(path: name)
        let profile = userData.appending(path: "Default")
        try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)

        let db = try openWritable(profile.appending(path: "Favicons"))
        defer { sqlite3_close_v2(db) }
        try exec(db, """
            CREATE TABLE icon_mapping(id INTEGER PRIMARY KEY, page_url LONGVARCHAR NOT NULL, \
            icon_id INTEGER, page_url_type INTEGER DEFAULT 0);
            CREATE TABLE favicons(id INTEGER PRIMARY KEY, url LONGVARCHAR NOT NULL, icon_type INTEGER DEFAULT 1);
            CREATE TABLE favicon_bitmaps(id INTEGER PRIMARY KEY, icon_id INTEGER NOT NULL, \
            last_updated INTEGER DEFAULT 0, image_data BLOB, width INTEGER DEFAULT 0, \
            height INTEGER DEFAULT 0, last_requested INTEGER DEFAULT 0);
            """)
        for (index, row) in rows.enumerated() {
            let iconID = index + 1
            try exec(db, "INSERT INTO icon_mapping(page_url, icon_id) VALUES('\(row.page)', \(iconID));")
            for size in row.sizes {
                try bindBitmap(db, iconID: iconID, data: try png(size: size), width: size)
            }
        }
        return userData
    }

    /// Adds one mapping plus one bitmap to an existing profile, for the tests
    /// that need the database to change between two lookups.
    private func addIcon(inProfileOf userData: URL, page: String, iconID: Int, data: Data, width: Int) throws {
        let db = try openWritable(userData.appending(path: "Default/Favicons"))
        defer { sqlite3_close_v2(db) }
        try exec(db, "INSERT INTO icon_mapping(page_url, icon_id) VALUES('\(page)', \(iconID));")
        try bindBitmap(db, iconID: iconID, data: data, width: width)
    }

    /// `<root>/Safari/Favicon Cache/{favicons.db, favicons/<MD5>}`.
    private func makeSafariCache(entries: [(storedURL: String, uuid: String, data: Data)]) throws -> FaviconSafariCache {
        let container = root.appending(path: "Safari")
        let cache = container.appending(path: "Favicon Cache")
        try FileManager.default.createDirectory(at: cache.appending(path: "favicons"), withIntermediateDirectories: true)

        let db = try openWritable(cache.appending(path: "favicons.db"))
        defer { sqlite3_close_v2(db) }
        try exec(db, "CREATE TABLE page_url(url TEXT UNIQUE NOT NULL, uuid TEXT NOT NULL);")
        for entry in entries {
            try exec(db, "INSERT INTO page_url(url, uuid) VALUES('\(entry.storedURL)', '\(entry.uuid)');")
            try entry.data.write(to: FaviconSafariSource.imageURL(directory: cache, uuid: entry.uuid))
        }
        return FaviconSafariCache(directory: container, securityScoped: false)
    }

    // MARK: SQLite helpers

    private func openWritable(_ url: URL) throws -> OpaquePointer {
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE
        guard sqlite3_open_v2(url.path, &db, flags, nil) == SQLITE_OK, let db else {
            sqlite3_close_v2(db)
            throw Failure.sqlite("open")
        }
        return db
    }

    private func exec(_ db: OpaquePointer, _ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw Failure.sqlite(sql) }
    }

    private func bindBitmap(_ db: OpaquePointer, iconID: Int, data: Data, width: Int) throws {
        var statement: OpaquePointer?
        let sql = "INSERT INTO favicon_bitmaps(icon_id, image_data, width, height) VALUES(?, ?, ?, ?);"
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw Failure.sqlite(sql)
        }
        defer { sqlite3_finalize(statement) }
        try data.withUnsafeBytes { buffer in
            sqlite3_bind_int(statement, 1, Int32(iconID))
            sqlite3_bind_blob(statement, 2, buffer.baseAddress, Int32(data.count), nil)
            sqlite3_bind_int(statement, 3, Int32(width))
            sqlite3_bind_int(statement, 4, Int32(width))
            guard sqlite3_step(statement) == SQLITE_DONE else { throw Failure.sqlite(sql) }
        }
    }

    // MARK: Image helpers

    private func png(size: Int) throws -> Data {
        let rep = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.red.setFill()
        NSRect(x: 0, y: 0, width: size, height: size).fill()
        NSGraphicsContext.restoreGraphicsState()
        return try XCTUnwrap(rep.representation(using: .png, properties: [:]))
    }

    private func pixelWidth(of data: Data) throws -> Int {
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        return image.width
    }

    private enum Failure: Error {
        case sqlite(String)
    }
}

/// Counts calls made from the engine's queue.
private final class CallCounter: Sendable {
    private let storage = Mutex<Int>(0)

    var count: Int { storage.withLock { $0 } }

    func increment() {
        storage.withLock { $0 += 1 }
    }
}
