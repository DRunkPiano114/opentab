import Foundation
import XCTest
@testable import OpenTab

@MainActor
final class UpdateControllerTests: XCTestCase {
    /// The updater is started from two Info.plist values, and an empty one of
    /// either is what a build that must never update itself carries. Quotes
    /// count as empty because the updater strips them before use.
    func testAFeedAndAKeyAreBothRequired() {
        XCTAssertFalse(UpdateController.isConfigured(feedURL: nil, publicKey: nil))
        XCTAssertFalse(UpdateController.isConfigured(feedURL: "", publicKey: "x"))
        XCTAssertFalse(UpdateController.isConfigured(feedURL: "x", publicKey: ""))
        XCTAssertFalse(UpdateController.isConfigured(feedURL: "  ", publicKey: "x"))
        XCTAssertFalse(UpdateController.isConfigured(feedURL: "\"\"", publicKey: "x"))
        XCTAssertTrue(UpdateController.isConfigured(feedURL: "https://example.invalid/appcast.xml",
                                                    publicKey: "jKM6wAMes4FHKOgWkD0oC0jPE0vdXvA+Nbn6RjMl4rA="))
    }

    /// The development build carries no feed, and this is the executable proof
    /// that it therefore starts no updater: it must never be able to replace
    /// itself with the released app.
    func testTheDevelopmentBundleStartsNoUpdater() {
        XCTAssertNil(UpdateController(bundle: .main),
                     "the development bundle has no feed and must start no updater")
    }

    /// Without an updater the toggle is off and inert. It must not fall back
    /// to a default of our own: two sources of truth for one preference means
    /// the switch and the updater eventually disagree.
    func testTheToggleWritesNothingWhenThereIsNoUpdater() {
        // A path as the suite name, so the plist lands in the temp directory
        // rather than ~/Library/Preferences.
        let suite = FileManager.default.temporaryDirectory
            .appending(path: "im.opentab.app.tests.updates.\(UUID().uuidString)").path
        let defaults = UserDefaults(suiteName: suite)!
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: URL(filePath: suite + ".plist"))
        }

        let store = SettingsStore(defaults: defaults, updates: nil)
        XCTAssertFalse(store.automaticUpdateChecks)
        store.automaticUpdateChecks = true

        let written = defaults.persistentDomain(forName: suite) ?? [:]
        XCTAssertEqual(written.keys.filter { $0.hasPrefix("SU") }, [])
    }
}
