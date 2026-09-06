import Carbon
import Foundation
import OpenTabCore
import OpenTabScript
import OpenTabWS
import XCTest
@testable import OpenTab

@MainActor
final class SettingsStoreTests: XCTestCase {
    private var suite: String!
    private var defaults: UserDefaults!

    override func setUp() {
        // The suite name is a path, so the plist lands in the temp directory rather
        // than ~/Library/Preferences, where cfprefsd leaves an empty one per test.
        suite = FileManager.default.temporaryDirectory
            .appending(path: "im.opentab.app.tests.settings.\(UUID().uuidString)").path
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: URL(filePath: suite + ".plist"))
    }

    /// The keys the settings window writes are the keys the components that
    /// act on them read. A rename on either side is otherwise invisible: the
    /// toggle moves and nothing happens.
    func testKeysMatchTheComponentsThatReadThem() {
        XCTAssertEqual(DefaultsKey.cmdTabTakeover, CmdTabTakeover.defaultsKey)
        XCTAssertEqual(DefaultsKey.remoteFavicons, FaviconStore.remoteLookupDefaultsKey)
        XCTAssertEqual(DefaultsKey.safariFaviconBookmark, FaviconSafariBookmark.defaultsKey)
        XCTAssertEqual(DefaultsKey.scanMaxElementID, OffSpaceConfiguration.maxElementIDKey)
        XCTAssertEqual(DefaultsKey.scanBudgetMilliseconds, OffSpaceConfiguration.budgetMillisecondsKey)
        XCTAssertEqual(DefaultsKey.skipInstallLocationCheck, InstallLocationPrompt.skipCheckDefaultsKey)
    }

    /// Excluding private windows and the favicon disclosure both rest on these
    /// being off for a user who has never opened the settings window.
    func testPrivacySettingsAreOffUntilTheUserOptsIn() {
        let store = SettingsStore(defaults: defaults)
        XCTAssertFalse(store.includesPrivateTabs)
        XCTAssertFalse(store.remoteFavicons)
        XCTAssertTrue(store.showMenuBarIcon)
        XCTAssertEqual(store.sortMode, .recency)
    }

    /// A domain that never stored a chord wants the takeover, and says so
    /// on disk from the first read, for the component that reads the flag
    /// without the chords.
    func testFreshStoreWantsTheTakeover() {
        let store = SettingsStore(defaults: defaults)
        XCTAssertEqual(store.mainHotKey, .cmdTab)
        XCTAssertEqual(store.reverseHotKey, .cmdShiftTab)
        XCTAssertTrue(store.cmdTabTakeover)
        XCTAssertTrue(defaults.bool(forKey: DefaultsKey.cmdTabTakeover))
    }

    /// The flag is derived from the chords and persisted next to them, for
    /// the component that reads the flag and knows nothing about chords.
    func testTakeoverFlagFollowsTheBoundChords() {
        let store = SettingsStore(defaults: defaults)
        store.mainHotKey = .optionTab
        store.reverseHotKey = .optionShiftTab
        XCTAssertFalse(store.cmdTabTakeover)
        XCTAssertFalse(defaults.bool(forKey: DefaultsKey.cmdTabTakeover))

        store.mainHotKey = .cmdTab
        XCTAssertTrue(store.cmdTabTakeover)
        XCTAssertTrue(defaults.bool(forKey: DefaultsKey.cmdTabTakeover))

        store.mainHotKey = .optionTab
        XCTAssertFalse(store.cmdTabTakeover)
        XCTAssertFalse(defaults.bool(forKey: DefaultsKey.cmdTabTakeover))
    }

    func testValuesSurviveARelaunch() {
        let store = SettingsStore(defaults: defaults)
        store.textSize = .large
        store.widePanel = true
        store.panelPosition = .right
        store.isAlphabetical = true
        store.includesPrivateTabs = true
        store.mainHotKey = HotKeyBinding(keyCode: UInt32(kVK_Space), carbonModifiers: UInt32(controlKey))

        let reopened = SettingsStore(defaults: defaults)
        XCTAssertEqual(reopened.textSize, .large)
        XCTAssertTrue(reopened.widePanel)
        XCTAssertEqual(reopened.panelPosition, .right)
        XCTAssertEqual(reopened.sortMode, .alphabetical)
        XCTAssertTrue(reopened.includesPrivateTabs)
        XCTAssertEqual(reopened.mainHotKey, HotKeyBinding(keyCode: UInt32(kVK_Space),
                                                          carbonModifiers: UInt32(controlKey)))
    }

    /// Every change is reported once, and writing the same value again is not
    /// a change: the private-tab switch rebuilds the whole index.
    func testEachChangeIsReportedOnce() {
        let store = SettingsStore(defaults: defaults)
        var reported: [Setting] = []
        store.onChange = { reported.append($0) }

        store.widePanel = true
        store.widePanel = true
        store.includesPrivateTabs = true
        store.searchHotKey = HotKeyBinding(keyCode: 1, carbonModifiers: UInt32(cmdKey))
        store.searchHotKey = HotKeyBinding(keyCode: 1, carbonModifiers: UInt32(cmdKey))

        XCTAssertEqual(reported.count, 3)
        XCTAssertEqual(reported, [.appearance, .includesPrivateTabs, .hotKeys])
    }

    /// The toggle drives the login item through the seam, once per change,
    /// and a failed registration shows as not having happened.
    func testLoginItemWritesGoThroughTheService() {
        let service = FakeLoginItem()
        let store = SettingsStore(defaults: defaults, loginItems: service)
        var reported: [Setting] = []
        store.onChange = { reported.append($0) }

        store.launchesAtLogin = true
        XCTAssertEqual(service.calls, [true])
        XCTAssertEqual(reported, [.launchAtLogin])

        store.launchesAtLogin = true
        XCTAssertEqual(service.calls, [true], "writing the same value again is not a change")

        service.error = FakeLoginItem.Failure()
        store.launchesAtLogin = false
        XCTAssertTrue(store.launchesAtLogin, "a failed write reverts to what the service reports")
        XCTAssertEqual(reported, [.launchAtLogin], "a failed write is not reported")
    }

    /// A default that is missing must not read as "off" for a setting whose
    /// default is on.
    func testMenuBarIconDefaultsOnAndCanBeTurnedOff() {
        let store = SettingsStore(defaults: defaults)
        store.showMenuBarIcon = false
        XCTAssertFalse(SettingsStore(defaults: defaults).showMenuBarIcon)
    }

    func testAutomationPaneIsOnlyOfferedAfterARequest() {
        let store = SettingsStore(defaults: defaults)
        XCTAssertFalse(store.hasRequestedAutomation)
        DefaultsAutomationRequestLog(defaults: defaults).markRequested("com.google.Chrome")
        XCTAssertTrue(store.hasRequestedAutomation)
    }
}
