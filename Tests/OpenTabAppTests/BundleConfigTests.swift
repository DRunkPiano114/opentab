import XCTest

/// Guards the Info.plist contract the TCC story depends on. Runs inside the
/// real OpenTab.app (TEST_HOST), which is what makes the app-hosted target the
/// place for anything that needs a live NSApplication event loop.
final class BundleConfigTests: XCTestCase {
    private var appInfo: [String: Any] {
        Bundle.main.infoDictionary ?? [:]
    }

    private var sparkleContents: URL {
        Bundle.main.bundleURL.appending(path: "Contents/Frameworks/Sparkle.framework/Versions/B")
    }

    func testRunsAsAgent() {
        XCTAssertEqual(appInfo["LSUIElement"] as? Bool, true)
    }

    func testDeclaresAppleEventsUsage() {
        XCTAssertFalse((appInfo["NSAppleEventsUsageDescription"] as? String ?? "").isEmpty)
    }

    /// Either check alone passes for the wrong host: xctest is not an OpenTab
    /// id, and a differently-named copy of the app is not OpenTab.
    func testHostIsTheRealApp() {
        XCTAssertEqual(Bundle.main.bundleIdentifier?.hasPrefix("im.opentab.app"), true)
        XCTAssertEqual(Bundle.main.executableURL?.lastPathComponent, "OpenTab")
    }

    /// The development host carries the key but no feed: a development copy
    /// with a feed could update itself into the release build.
    func testDebugHostHasAnEmptyFeed() {
        XCTAssertEqual(appInfo["SUFeedURL"] as? String, "")
    }

    func testCarriesTheUpdatePublicKey() {
        XCTAssertFalse((appInfo["SUPublicEDKey"] as? String ?? "").isEmpty,
                       "fill OPENTAB_SPARKLE_PUBLIC_KEY in project.yml")
    }

    func testChecksForUpdatesAutomatically() {
        XCTAssertEqual(appInfo["SUEnableAutomaticChecks"] as? Bool, true)
    }

    func testVerifiesUpdatesBeforeExtraction() {
        XCTAssertEqual(appInfo["SUVerifyUpdateBeforeExtraction"] as? Bool, true)
    }

    func testRequiresASignedFeed() {
        XCTAssertEqual(appInfo["SURequireSignedFeed"] as? Bool, true)
    }

    /// Whether updates install on their own is left to Sparkle's defaults;
    /// pinning the keys absent is what catches a later addition.
    func testLeavesAutomaticInstallToSparkle() {
        XCTAssertNil(appInfo["SUAllowsAutomaticUpdates"])
    }

    func testLeavesSilentInstallToSparkle() {
        XCTAssertNil(appInfo["SUAutomaticallyUpdate"])
    }

    /// The XPC services serve sandboxed hosts only and the build removes them.
    func testSparkleXPCServicesAreRemoved() {
        XCTAssertFalse(FileManager.default.fileExists(atPath: sparkleContents.appending(path: "XPCServices").path))
    }

    func testSparkleHelpersAreEmbedded() {
        for helper in ["Autoupdate", "Updater.app"] {
            let path = sparkleContents.appending(path: helper).path
            XCTAssertTrue(FileManager.default.fileExists(atPath: path), "missing \(path)")
        }
    }
}
