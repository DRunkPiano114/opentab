import XCTest

/// Guards the Info.plist contract the TCC story depends on. Runs inside the
/// real OpenTab.app (TEST_HOST), which is what makes the app-hosted target the
/// place for anything that needs a live NSApplication event loop.
final class BundleConfigTests: XCTestCase {
    private var appInfo: [String: Any] {
        Bundle.main.infoDictionary ?? [:]
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
}
