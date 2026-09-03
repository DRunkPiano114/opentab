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
        suite = "im.opentab.app.tests.settingsui.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
    }

    private func layout(_ view: some View) -> NSView {
        let controller = NSHostingController(rootView: view)
        let window = NSWindow(contentViewController: controller)
        window.layoutIfNeeded()
        controller.view.layoutSubtreeIfNeeded()
        return controller.view
    }

    func testEverySettingsPageLaysOut() {
        let store = SettingsStore(defaults: defaults)
        let model = SettingsModel()
        model.tabsUnavailable = ["Safari"]
        model.tabsAwaitingRequest = [(bundleID: "com.google.Chrome", name: "Google Chrome")]
        model.windowIDBridgeAvailable = false
        model.secureInputActive = true
        model.cmdTabTakeoverAvailable = false
        let view = layout(SettingsView(store: store, model: model, actions: SettingsActions()))
        XCTAssertGreaterThan(view.fittingSize.width, 0)
        XCTAssertGreaterThan(view.fittingSize.height, 0)
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
        let view = HotKeyRecorderView(binding: .mainDefault, requiresHoldModifier: true)
        var recorded: [HotKeyBinding] = []
        view.onRecord = { recorded.append($0) }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 40),
                              styleMask: [.titled], backing: .buffered, defer: true)
        window.contentView?.addSubview(view)
        window.makeFirstResponder(view)
        view.mouseDown(with: keyEvent(keyCode: 0, flags: []))

        view.keyDown(with: keyEvent(keyCode: 122, flags: []))
        XCTAssertTrue(recorded.isEmpty, "a bare key would be stolen from every app")

        view.keyDown(with: keyEvent(keyCode: 48, flags: .shift))
        XCTAssertTrue(recorded.isEmpty, "shift alone cannot be the hold modifier")

        view.keyDown(with: keyEvent(keyCode: 49, flags: .control))
        XCTAssertEqual(recorded, [HotKeyBinding(keyCode: 49, carbonModifiers: UInt32(controlKey))])
    }

    private func keyEvent(keyCode: UInt16, flags: NSEvent.ModifierFlags) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                         windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "",
                         isARepeat: false, keyCode: keyCode)!
    }
}
