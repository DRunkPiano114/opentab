import XCTest

/// Guards the Info.plist contract the TCC story depends on. Runs inside the
/// real OpenTab.app (TEST_HOST), which is what makes the app-hosted target the
/// place for anything that needs a live NSApplication event loop (L12).
final class BundleConfigTests: XCTestCase {
    private var appInfo: [String: Any] {
        let host = Bundle(identifier: "im.opentab.app") ?? Bundle.main
        return host.infoDictionary ?? [:]
    }

    func testRunsAsAgent() {
        XCTAssertEqual(appInfo["LSUIElement"] as? Bool, true)
    }

    func testDeclaresAppleEventsUsage() {
        XCTAssertFalse((appInfo["NSAppleEventsUsageDescription"] as? String ?? "").isEmpty)
    }

    func testHostIsTheRealApp() {
        XCTAssertEqual(Bundle.main.bundleIdentifier, "im.opentab.app")
    }
}
