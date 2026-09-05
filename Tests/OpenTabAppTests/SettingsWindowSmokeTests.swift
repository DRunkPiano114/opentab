import AppKit
import Carbon
import SwiftUI
import XCTest
@testable import OpenTab

/// The settings and first-run views only fail on layout, which no unit test
/// of the model would reach. These build the real hosting controllers and
/// force a layout pass, so a broken view tree fails here rather than the
/// first time a user opens the window.
@MainActor
final class SettingsWindowSmokeTests: XCTestCase {
    private var suite: String!
    private var defaults: UserDefaults!

    override func setUp() {
        // The suite name is a path, so the plist lands in the temp directory rather
        // than ~/Library/Preferences, where cfprefsd leaves an empty one per test.
        suite = FileManager.default.temporaryDirectory
            .appending(path: "im.opentab.app.tests.settingsui.\(UUID().uuidString)").path
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: URL(filePath: suite + ".plist"))
    }

    private func layout(_ view: some View) -> NSView {
        let controller = NSHostingController(rootView: view)
        let window = NSWindow(contentViewController: controller)
        window.layoutIfNeeded()
        controller.view.layoutSubtreeIfNeeded()
        return controller.view
    }

    /// Every row a page can grow is present, so a page only ever lays out
    /// fewer views in the running app than it does here.
    private func degradedModel() -> SettingsModel {
        let model = SettingsModel()
        model.tabsUnavailable = ["Safari"]
        model.tabsAwaitingRequest = [(bundleID: "com.google.Chrome", name: "Google Chrome")]
        model.windowIDBridgeAvailable = false
        model.secureInputActive = true
        model.cmdTabTakeoverAvailable = false
        model.takeoverPolicy = .unavailable
        model.updatesAvailable = true
        return model
    }

    private func assertLaysOut(_ view: some View, _ message: String) {
        let laid = layout(view)
        XCTAssertGreaterThan(laid.fittingSize.width, 0, message)
        XCTAssertGreaterThan(laid.fittingSize.height, 0, message)
    }

    func testGeneralPageLaysOut() {
        assertLaysOut(GeneralSettingsView(store: SettingsStore(defaults: defaults), model: degradedModel(),
                                          actions: SettingsActions()), "General")
    }

    func testShortcutsPageLaysOut() {
        assertLaysOut(HotKeySettingsView(store: SettingsStore(defaults: defaults), model: degradedModel(),
                                         actions: SettingsActions()), "Shortcuts")
    }

    func testPrivacyPageLaysOut() {
        assertLaysOut(PrivacySettingsView(store: SettingsStore(defaults: defaults), model: degradedModel(),
                                          actions: SettingsActions()), "Privacy")
    }

    func testAboutPageLaysOut() {
        assertLaysOut(AboutSettingsView(store: SettingsStore(defaults: defaults), model: degradedModel(),
                                        actions: SettingsActions()), "About")
    }

    /// Switching away from the Shortcuts page no longer takes the field out of
    /// the view hierarchy, so the tab switch is the only thing left that can
    /// end a capture.
    func testTabSwitchEndsRecording() {
        var recording: [Bool] = []
        var actions = SettingsActions()
        actions.setRecording = { recording.append($0) }
        let controller = SettingsTabController(store: SettingsStore(defaults: defaults),
                                               model: SettingsModel(), actions: actions)
        let window = NSWindow(contentViewController: controller)
        window.layoutIfNeeded()
        for tab in [SettingsTabController.Tab.shortcuts, .general] {
            recording.removeAll()
            controller.select(tab)
            window.layoutIfNeeded()
            XCTAssertTrue(recording.contains(false), "switching to \(tab) must end any capture")
            XCTAssertFalse(recording.contains(true), "a tab switch must not start one")
        }
    }

    /// The window height is driven from these, and a page never shown reports
    /// nothing at all.
    func testEachPageDeclaresAPreferredContentSize() {
        let controller = SettingsTabController(store: SettingsStore(defaults: defaults),
                                               model: degradedModel(), actions: SettingsActions())
        let window = NSWindow(contentViewController: controller)
        for tab in SettingsTabController.Tab.allCases {
            controller.select(tab)
            window.layoutIfNeeded()
            let page = controller.tabViewItems[tab.rawValue].viewController
            XCTAssertGreaterThan(page?.preferredContentSize.height ?? 0, 0, "\(tab)")
        }
    }

    func testEveryOnboardingStepLaysOut() {
        let model = OnboardingModel()
        for _ in OnboardingModel.Step.allCases {
            let view = layout(OnboardingView(model: model, promptForAccessibility: {},
                                             openAccessibilitySettings: {}, finish: {}))
            XCTAssertGreaterThan(view.fittingSize.height, 0)
            model.accessibilityChanged(true)
            model.advance()
        }
        XCTAssertEqual(model.step, .done)
    }

    /// While a shortcut field is capturing, the global chords are released so
    /// it can see them. Anything that ends the capture has to put them back.
    func testRecorderReleasesAndRestoresTheGlobalChords() {
        var recording: [Bool] = []
        var actions = SettingsActions()
        actions.setRecording = { recording.append($0) }
        let controller = SettingsWindowController(store: SettingsStore(defaults: defaults),
                                                  model: SettingsModel(), actions: actions)
        controller.windowWillClose(Notification(name: NSWindow.willCloseNotification))
        XCTAssertEqual(recording, [false], "closing the window must end any capture")
    }

    func testRecorderRejectsChordsThatCannotDriveThePanel() {
        let main = { HotKeyRecorderView(binding: .mainDefault, requiresHoldModifier: true) }
        XCTAssertTrue(recorded(122, [], in: main()).isEmpty, "a bare key would be stolen from every app")
        XCTAssertTrue(recorded(48, .shift, in: main()).isEmpty, "shift alone cannot be the hold modifier")
        XCTAssertEqual(recorded(49, .control, in: main()), [HotKeyBinding(keyCode: 49, carbonModifiers: UInt32(controlKey))])

        XCTAssertEqual(recorded(48, .command, in: HotKeyRecorderView(binding: .mainDefault, requiresHoldModifier: true,
                                                                       takeoverAvailable: true)),
                       [.cmdTab], "Cmd-Tab is an ordinary value for the main field")
        XCTAssertTrue(recorded(48, .command, in: HotKeyRecorderView(binding: .mainDefault, requiresHoldModifier: true,
                                                                      takeoverAvailable: false)).isEmpty,
                      "without the window-server call Cmd-Tab could never fire")

        let search = { HotKeyRecorderView(binding: .searchDefault, requiresHoldModifier: false, acceptsCmdTab: false) }
        XCTAssertTrue(recorded(48, .command, in: search()).isEmpty,
                      "search never switches the system chord off, so Cmd-Tab there would never fire")
        XCTAssertEqual(recorded(37, [.command, .shift], in: search()),
                       [HotKeyBinding(keyCode: 37, carbonModifiers: UInt32(cmdKey | shiftKey))])

        let reserved = { HotKeyRecorderView(binding: .mainDefault, requiresHoldModifier: true, reservedChords: [.optionTab]) }
        XCTAssertTrue(recorded(48, .option, in: reserved()).isEmpty, "another field has it")
        XCTAssertTrue(recorded(48, .command, in: reserved()).isEmpty, "its fallback is another field's chord")
    }

    /// Drives one capture the way a click and a key press would, on a view
    /// that is not yet recording.
    private func recorded(_ keyCode: UInt16, _ flags: NSEvent.ModifierFlags,
                          in view: HotKeyRecorderView) -> [HotKeyBinding] {
        var recorded: [HotKeyBinding] = []
        view.onRecord = { recorded.append($0) }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 40),
                              styleMask: [.titled], backing: .buffered, defer: true)
        window.contentView?.addSubview(view)
        window.makeFirstResponder(view)
        view.mouseDown(with: keyEvent(keyCode: 0, flags: []))
        view.keyDown(with: keyEvent(keyCode: keyCode, flags: flags))
        return recorded
    }

    private func keyEvent(keyCode: UInt16, flags: NSEvent.ModifierFlags) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                         windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "",
                         isARepeat: false, keyCode: keyCode)!
    }
}
