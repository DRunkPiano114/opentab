import AppKit
import OpenTabAX
import OpenTabCore
import OpenTabScript
import XCTest
@testable import OpenTab

/// Which apps are refused an Accessibility tab read.
///
/// The rule guards one thing: a browser can show a private window whose tab
/// titles the Accessibility tree exposes and whose privacy it gives no way to
/// detect. It must catch every such browser and nothing else — a native
/// tab app wrongly judged a browser loses its tabs silently.
@MainActor
final class TabProviderRegistryTests: XCTestCase {
    private func app(_ bundleID: String) -> AppInfo {
        AppInfo(bundleID: bundleID, pid: 0, localizedName: bundleID)
    }

    private func installedURL(_ bundleID: String) -> URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
    }

    // MARK: - Not browsers

    /// iTerm2 registers the `https` scheme so it can open a link, which is why
    /// asking Launch Services who handles `https` is the wrong question.
    func testTerminalWithNativeTabsIsNotABrowser() throws {
        let bundleID = "com.googlecode.iterm2"
        let url = try XCTUnwrap(installedURL(bundleID), "iTerm2 is not installed")
        XCTAssertFalse(TabProviderRegistry.isBrowser(app(bundleID), appURL: url))
    }

    func testFinderAndOtherNativeTabAppsAreNotBrowsers() {
        for bundleID in ["com.apple.finder", "com.mitchellh.ghostty", "com.apple.Terminal"] {
            XCTAssertFalse(TabProviderRegistry.isBrowser(app(bundleID), appURL: installedURL(bundleID)),
                           "\(bundleID) must keep its Accessibility tab read")
        }
    }

    // MARK: - Browsers

    func testSafariIsABrowser() {
        XCTAssertTrue(TabProviderRegistry.isBrowser(app("com.apple.Safari"), appURL: nil))
        XCTAssertTrue(TabProviderRegistry.isBrowser(app("com.apple.SafariTechnologyPreview"), appURL: nil))
    }

    /// Chromium is decided by the scripting-suite probe, not by its bundle id,
    /// so a fork nobody enumerated is caught as well.
    func testChromiumIsABrowserThroughTheScriptingProbe() throws {
        let bundleID = "com.google.Chrome"
        let url = try XCTUnwrap(installedURL(bundleID), "Google Chrome is not installed")
        XCTAssertFalse(TabProviderRegistry.namedBrowserBundleIDs.contains(bundleID))
        XCTAssertTrue(TabProviderRegistry.isBrowser(app(bundleID), appURL: url))
    }

    /// Engines with no probe of their own are named instead.
    func testGeckoAndOtherEnginesAreNamed() {
        for bundleID in ["org.mozilla.firefox", "company.thebrowser.Browser", "com.kagi.kagimacOS"] {
            XCTAssertTrue(TabProviderRegistry.isBrowser(app(bundleID), appURL: nil), bundleID)
        }
    }

    // MARK: - What the registry hands out

    func testANativeTabAppGetsTheAccessibilityProvider() {
        let registry = TabProviderRegistry(engine: AppleScriptEngine(), includesPrivate: false)
        let provider = registry.provider(for: app("com.example.native-tabs"))
        XCTAssertTrue(provider is any AccessibilityTabReads)
        XCTAssertFalse(registry.usesAppleEvents(for: app("com.example.native-tabs")))
    }

    /// Safari has no provider without the opt-in, and never falls through to
    /// the Accessibility scan.
    func testSafariGetsNoProviderWithoutTheOptIn() {
        let registry = TabProviderRegistry(engine: AppleScriptEngine(), includesPrivate: false)
        XCTAssertNil(registry.provider(for: app("com.apple.Safari")))
    }

    func testAnUnprobeableBrowserGetsNoProviderWithoutTheOptIn() {
        let registry = TabProviderRegistry(engine: AppleScriptEngine(), includesPrivate: false)
        XCTAssertNil(registry.provider(for: app("org.mozilla.firefox")))
    }

    func testTheOptInLetsAnUnprobeableBrowserUseAccessibility() {
        let registry = TabProviderRegistry(engine: AppleScriptEngine(), includesPrivate: true)
        XCTAssertTrue(registry.provider(for: app("org.mozilla.firefox")) is any AccessibilityTabReads)
    }
}
