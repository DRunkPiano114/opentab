import AppKit
import OpenTabAX
import SwiftUI

/// Hosts the first-run flow. Alive only until the user finishes it, and the
/// app delegate waits for `onFinish` before putting anything else modal in
/// front of them.
@MainActor
final class OnboardingWindowController: NSObject, NSWindowDelegate {
    let model = OnboardingModel()
    /// Called once, when the flow ends.
    var onFinish: (() -> Void)?
    /// The settings the flow writes its choices into.
    private(set) var store: SettingsStore?
    /// Whether this Mac can take Cmd-Tab over at all.
    private(set) var takeoverAvailable = true
    /// True while the flow is up and the shortcuts step has not been
    /// confirmed. The app treats the takeover as not wanted meanwhile, so the
    /// stored Cmd-Tab default does not take over at the Accessibility step,
    /// one step before the sentence that says what Cmd-Tab replaces.
    var holdsTakeover = false
    /// Called whenever `holdsTakeover` changes.
    var onHoldChanged: (() -> Void)?

    private var window: NSWindow?

    var isActive: Bool { window != nil }

    /// Wires the flow to the settings it writes into. Separate from `show` so
    /// the wiring can be exercised without putting a window on screen.
    func configure(store: SettingsStore, takeoverAvailable: Bool) {
        self.store = store
        self.takeoverAvailable = takeoverAvailable
        model.takeoverAvailable = takeoverAvailable
        model.accessibilityGranted = AXTrust.isTrusted
        holdsTakeover = true
        onHoldChanged?()
        model.onShortcutsChosen = { [weak self, weak store] choice, opensAtLogin in
            store?.mainHotKey = choice.main
            store?.reverseHotKey = choice.reverse
            store?.launchesAtLogin = opensAtLogin
            // Released last, so the takeover is evaluated against the chords
            // that were just written.
            self?.holdsTakeover = false
            self?.onHoldChanged?()
        }
    }

    func show(store: SettingsStore, takeoverAvailable: Bool) {
        guard window == nil else { return }
        configure(store: store, takeoverAvailable: takeoverAvailable)

        let view = OnboardingView(model: model,
                                  promptForAccessibility: { [weak self] in
                                      self?.model.markPrompted()
                                      AXTrust.prompt()
                                  },
                                  openAccessibilitySettings: {
                                      NSWorkspace.shared.open(SystemSettingsLinks.accessibility)
                                  },
                                  finish: { [weak self] in self?.finish() })
        let window = NSWindow(contentViewController: NSHostingController(rootView: view))
        window.title = "OpenTab"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.delegate = self
        self.window = window
        NSApp.activate()
        window.center()
        window.makeKeyAndOrderFront(nil)
    }

    func accessibilityChanged(_ granted: Bool) {
        model.accessibilityChanged(granted)
    }

    /// Dismissing the window counts as finishing: the flow is not shown
    /// again, and whatever it was holding back goes ahead. Without this a
    /// closed window would leave the app waiting on a flow that is gone.
    func windowWillClose(_ notification: Notification) {
        guard window != nil else { return }
        window = nil
        finishFlow()
    }

    /// Ends the flow from wherever it stopped: the choice the user was shown
    /// is applied, the hold goes, and the app is told. `onFinish` re-evaluates
    /// the takeover itself, so the hold is dropped without announcing it.
    func finishFlow() {
        model.applySelectionIfReached()
        holdsTakeover = false
        onFinish?()
    }

    /// Closing is the single exit; `windowWillClose` does the rest.
    private func finish() {
        window?.close()
    }
}
