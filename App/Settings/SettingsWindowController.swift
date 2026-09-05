import AppKit

/// The settings window.
///
/// A plain `NSWindow` rather than SwiftUI's `Settings` scene: that scene only
/// exists inside a SwiftUI `App`, and this app's entry point is an
/// `NSApplication` with a delegate.
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private let store: SettingsStore
    private let model: SettingsModel
    private let actions: SettingsActions
    private var window: NSWindow?
    private var tabs: SettingsTabController?

    init(store: SettingsStore, model: SettingsModel, actions: SettingsActions) {
        self.store = store
        self.model = model
        self.actions = actions
        super.init()
    }

    /// A shortcut field that was still capturing when the window went away
    /// would leave the global chords unregistered, which looks exactly like
    /// the app having died.
    func windowWillClose(_ notification: Notification) {
        actions.setRecording(false)
    }

    var isVisible: Bool { window?.isVisible ?? false }

    func show(tab: SettingsTabController.Tab? = nil) {
        actions.refreshHealth()
        let existing = window
        let window = existing ?? makeWindow()
        self.window = window
        // An accessory app is not active when its status item is clicked, and
        // an inactive window would take no keystrokes.
        NSApp.activate()
        if existing == nil { window.center() }
        if let tab { tabs?.select(tab) }
        window.makeKeyAndOrderFront(nil)
    }

    private func makeWindow() -> NSWindow {
        let controller = SettingsTabController(store: store, model: model, actions: actions)
        tabs = controller
        let window = NSWindow(contentViewController: controller)
        // Until the first selection propagates a page title.
        window.title = "Settings"
        window.styleMask = [.titled, .closable, .miniaturizable]
        // A preference window is fixed-width and its height follows the page,
        // which is why it is not resizable.
        window.toolbarStyle = .preference
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.setContentSize(controller.initialContentSize)
        return window
    }
}
