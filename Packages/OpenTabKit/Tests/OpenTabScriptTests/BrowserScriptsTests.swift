import XCTest
@testable import OpenTabScript

final class BrowserScriptsTests: XCTestCase {
    func testEveryScriptAddressesTheTargetByBundleIDAndIsTimeBounded() {
        let sources = [
            BrowserScripts.safariReadTabs(bundleID: "com.apple.Safari"),
            BrowserScripts.safariActivateTab(bundleID: "com.apple.Safari", windowID: "1", tabIndex: 2),
            BrowserScripts.safariCloseTab(bundleID: "com.apple.Safari", windowID: "1", tabIndex: 2),
            BrowserScripts.chromiumReadTabs(bundleID: "com.google.Chrome"),
            BrowserScripts.chromiumActivateTab(bundleID: "com.google.Chrome", windowID: "1", tabID: "9"),
            BrowserScripts.chromiumCloseTab(bundleID: "com.google.Chrome", windowID: "1", tabID: "9"),
        ]
        for source in sources {
            XCTAssertTrue(source.contains("tell application id \""), source)
            XCTAssertFalse(source.contains("tell application \""), "must never address by name")
            XCTAssertTrue(source.hasPrefix("with timeout of 2 seconds\n"), source)
            XCTAssertTrue(source.hasSuffix("\nend timeout"), source)
        }
    }

    func testReadScriptsUseTheBulkPluralForm() {
        let safari = BrowserScripts.safariReadTabs(bundleID: "com.apple.Safari")
        XCTAssertTrue(safari.contains("(name of every tab of browserWindow)"))
        XCTAssertTrue(safari.contains("(URL of every tab of browserWindow)"))
        XCTAssertTrue(safari.contains("(index of every tab of browserWindow)"))

        let chromium = BrowserScripts.chromiumReadTabs(bundleID: "com.google.Chrome")
        XCTAssertTrue(chromium.contains("(title of every tab of browserWindow)"))
        XCTAssertTrue(chromium.contains("(id of every tab of browserWindow)"))
        XCTAssertTrue(chromium.contains("mode of browserWindow"))
    }

    func testCloseScriptDoesNotActivateTheTarget() {
        for source in [BrowserScripts.safariCloseTab(bundleID: "com.apple.Safari", windowID: "1", tabIndex: 2),
                       BrowserScripts.chromiumCloseTab(bundleID: "com.google.Chrome", windowID: "1", tabID: "9")] {
            XCTAssertTrue(source.contains("close tab"))
            XCTAssertFalse(source.contains("activate"))
            XCTAssertFalse(source.contains("active tab index"))
        }
    }

    func testIdentifiersAreQuotedIntoTheSource() {
        let source = BrowserScripts.chromiumActivateTab(bundleID: "com.google.Chrome",
                                                        windowID: "13\"91",
                                                        tabID: "a\\b")
        XCTAssertTrue(source.contains("\"13\\\"91\""))
        XCTAssertTrue(source.contains("\"a\\\\b\""))
    }

    func testLiteralEscaping() {
        XCTAssertEqual(AppleScriptLiteral.quoted("plain"), "\"plain\"")
        XCTAssertEqual(AppleScriptLiteral.quoted("a\"b"), "\"a\\\"b\"")
        XCTAssertEqual(AppleScriptLiteral.quoted("a\\b"), "\"a\\\\b\"")
        XCTAssertEqual(AppleScriptLiteral.quoted("a\nb"), "\"a\\nb\"")
        XCTAssertEqual(AppleScriptLiteral.quoted("a\tb"), "\"a\\tb\"")
    }

    /// Compiling resolves the target's terminology from its bundle; it sends no
    /// Apple Event and needs no automation grant. It does need the browsers to
    /// be installed, so it is opt-in.
    func testScriptsCompileAgainstTheRealDictionaries() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["OPENTAB_SCRIPT_COMPILE"] == "1",
                          "set OPENTAB_SCRIPT_COMPILE=1 on a machine with Safari and Chrome")
        let sources = [
            BrowserScripts.safariReadTabs(bundleID: "com.apple.Safari"),
            BrowserScripts.safariActivateTab(bundleID: "com.apple.Safari", windowID: "36879", tabIndex: 2),
            BrowserScripts.safariCloseTab(bundleID: "com.apple.Safari", windowID: "36879", tabIndex: 2),
            BrowserScripts.chromiumReadTabs(bundleID: "com.google.Chrome"),
            BrowserScripts.chromiumActivateTab(bundleID: "com.google.Chrome", windowID: "1391121581", tabID: "1391122136"),
            BrowserScripts.chromiumCloseTab(bundleID: "com.google.Chrome", windowID: "1391121581", tabID: "1391122136"),
        ]
        for source in sources {
            let script = try XCTUnwrap(NSAppleScript(source: source))
            var error: NSDictionary?
            XCTAssertTrue(script.compileAndReturnError(&error), "\(error ?? [:])")
        }
    }
}
