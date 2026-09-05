import Foundation
import XCTest
@testable import OpenTab

@MainActor
final class OnboardingTests: XCTestCase {
    private var suite: String!
    private var defaults: UserDefaults!

    override func setUp() {
        // The suite name is a path, so the plist lands in the temp directory rather
        // than ~/Library/Preferences, where cfprefsd leaves an empty one per test.
        suite = FileManager.default.temporaryDirectory
            .appending(path: "im.opentab.app.tests.onboarding.\(UUID().uuidString)").path
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: URL(filePath: suite + ".plist"))
    }

    /// The Accessibility grant lands without a relaunch, so the flow must
    /// notice it and move on by itself. Telling the user to quit and reopen
    /// would be inventing a restriction macOS does not impose.
    func testAccessibilityStepAdvancesItselfWhenTheGrantLands() {
        let model = OnboardingModel()
        model.advance()
        model.advance()
        XCTAssertEqual(model.step, .accessibility)

        model.accessibilityChanged(true)
        XCTAssertEqual(model.step, .shortcuts)
    }

    func testAccessibilityStepDoesNotOfferAWayPast() {
        let model = OnboardingModel()
        model.advance()
        model.advance()
        XCTAssertEqual(model.step, .accessibility)
        XCTAssertFalse(model.canAdvance)

        model.advance()
        XCTAssertEqual(model.step, .accessibility, "nothing after this step works without the grant")
    }

    /// A grant that arrives before the user reaches the step must not skip
    /// past whatever step they are on.
    func testAGrantOnAnEarlierStepDoesNotJumpTheFlow() {
        let model = OnboardingModel()
        model.accessibilityChanged(true)
        XCTAssertEqual(model.step, .welcome)
        XCTAssertTrue(model.accessibilityGranted)

        model.advance()
        model.advance()
        XCTAssertEqual(model.step, .accessibility)
        XCTAssertTrue(model.canAdvance)
    }

    func testFlowRunsToTheEndAndStopsThere() {
        let model = OnboardingModel()
        model.accessibilityChanged(true)
        for _ in 0..<10 { model.advance() }
        XCTAssertEqual(model.step, .done)
        XCTAssertTrue(model.isLast)
    }

    func testBackStopsAtTheFirstStep() {
        let model = OnboardingModel()
        model.back()
        XCTAssertEqual(model.step, .welcome)
    }

    // MARK: The shortcut choice

    func testShortcutChoiceDefaultsToTheTakeoverChordWithLoginItem() {
        let model = OnboardingModel()
        XCTAssertEqual(model.shortcutChoice, .cmdTab)
        XCTAssertTrue(model.opensAtLogin)
        XCTAssertEqual(model.mainHotKey, .cmdTab)
        XCTAssertEqual(model.reverseHotKey, .cmdShiftTab)
    }

    /// A Mac that cannot take the chord over must never be offered it: the
    /// step would show a shortcut that does nothing.
    func testUnavailableTakeoverPreselectsOptionTab() {
        let model = OnboardingModel()
        model.takeoverAvailable = false
        XCTAssertEqual(model.shortcutChoice, .optionTab)
        XCTAssertFalse(model.opensAtLogin)
        XCTAssertEqual(model.mainHotKey, .optionTab)
    }

    /// The box follows the choice, and stays where the user last put it.
    func testChoosingOptionTabUnticksLoginAndTheUserCanRetick() {
        let model = OnboardingModel()
        model.shortcutChoice = .optionTab
        XCTAssertFalse(model.opensAtLogin)

        model.opensAtLogin = true
        XCTAssertTrue(model.opensAtLogin)

        model.shortcutChoice = .cmdTab
        XCTAssertTrue(model.opensAtLogin)
    }

    func testConfirmingTheShortcutStepWritesTheStore() {
        let loginItems = FakeLoginItem()
        let store = SettingsStore(defaults: defaults, loginItems: loginItems)
        let controller = OnboardingWindowController()
        controller.configure(store: store, takeoverAvailable: true)
        driveToShortcuts(controller.model)

        controller.model.advance()

        XCTAssertEqual(store.mainHotKey, .cmdTab)
        XCTAssertEqual(store.reverseHotKey, .cmdShiftTab)
        XCTAssertTrue(store.launchesAtLogin)
        XCTAssertEqual(loginItems.calls, [true], "the login item is registered once, on confirm")
    }

    func testChoosingOptionTabRequestsNoLoginItem() {
        let loginItems = FakeLoginItem()
        let store = SettingsStore(defaults: defaults, loginItems: loginItems)
        let controller = OnboardingWindowController()
        controller.configure(store: store, takeoverAvailable: true)
        driveToShortcuts(controller.model)
        controller.model.shortcutChoice = .optionTab

        controller.model.advance()

        XCTAssertEqual(store.mainHotKey, .optionTab)
        XCTAssertEqual(store.reverseHotKey, .optionShiftTab)
        XCTAssertTrue(loginItems.calls.isEmpty)
    }

    /// Closing the window is an exit like any other, so the step the user was
    /// looking at still counts.
    func testClosingAfterTheShortcutStepAppliesTheSelection() {
        let loginItems = FakeLoginItem()
        let store = SettingsStore(defaults: defaults, loginItems: loginItems)
        let controller = OnboardingWindowController()
        var finishes = 0
        controller.onFinish = { finishes += 1 }
        controller.configure(store: store, takeoverAvailable: true)
        driveToShortcuts(controller.model)
        controller.model.shortcutChoice = .optionTab

        controller.finishFlow()

        XCTAssertEqual(store.mainHotKey, .optionTab)
        XCTAssertEqual(store.reverseHotKey, .optionShiftTab)
        XCTAssertEqual(finishes, 1)
    }

    /// Nobody gets a login item or a rebinding out of a choice they were never
    /// shown.
    func testClosingBeforeTheShortcutStepWritesNothing() {
        let loginItems = FakeLoginItem()
        let store = SettingsStore(defaults: defaults, loginItems: loginItems)
        let controller = OnboardingWindowController()
        var finishes = 0
        controller.onFinish = { finishes += 1 }
        controller.configure(store: store, takeoverAvailable: true)

        controller.finishFlow()

        XCTAssertNil(defaults.object(forKey: DefaultsKey.mainHotKey))
        XCTAssertNil(defaults.object(forKey: DefaultsKey.reverseHotKey))
        XCTAssertTrue(loginItems.calls.isEmpty)
        XCTAssertEqual(finishes, 1)
    }

    func testShortcutsStepStaysBehindTheGrant() {
        let model = OnboardingModel()
        for _ in 0..<10 { model.advance() }
        XCTAssertEqual(model.step, .accessibility)
        XCTAssertFalse(model.hasReachedShortcuts)
    }

    /// The stored Cmd-Tab default must not take the system switcher over at the
    /// Accessibility step, one step before the sentence that says what it
    /// replaces.
    func testTakeoverIsHeldUntilTheStepIsConfirmed() {
        let store = SettingsStore(defaults: defaults, loginItems: FakeLoginItem())
        let controller = OnboardingWindowController()
        var holdChanges = 0
        controller.onHoldChanged = { holdChanges += 1 }

        controller.configure(store: store, takeoverAvailable: true)
        XCTAssertTrue(controller.holdsTakeover)
        XCTAssertEqual(holdChanges, 1)

        driveToShortcuts(controller.model)
        XCTAssertTrue(controller.holdsTakeover, "the hold outlasts every step before the choice")

        controller.model.advance()
        XCTAssertFalse(controller.holdsTakeover)
        XCTAssertEqual(holdChanges, 2)

        let closed = OnboardingWindowController()
        closed.configure(store: store, takeoverAvailable: true)
        var closedHoldChanges = 0
        closed.onHoldChanged = { closedHoldChanges += 1 }
        closed.finishFlow()
        XCTAssertFalse(closed.holdsTakeover)
        XCTAssertEqual(closedHoldChanges, 0, "finishing re-evaluates the takeover on its own")
    }

    /// Grant, then welcome to what to accessibility to shortcuts.
    private func driveToShortcuts(_ model: OnboardingModel) {
        model.accessibilityChanged(true)
        for _ in 0..<3 { model.advance() }
        XCTAssertEqual(model.step, .shortcuts)
    }
}
