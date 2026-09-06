import AppKit
import SwiftUI

/// One toolbar tab per settings page, the way a macOS preferences window is
/// built. AppKit rather than SwiftUI: a toolbar-style tab bar exists nowhere
/// else, and nothing resizes the window to the page on its own.
@MainActor
final class SettingsTabController: NSTabViewController {
    enum Tab: Int, CaseIterable {
        case general, shortcuts, privacy, about

        var label: String {
            switch self {
            case .general: "General"
            case .shortcuts: "Shortcuts"
            case .privacy: "Privacy"
            case .about: "About"
            }
        }

        var symbol: String {
            switch self {
            case .general: "gearshape"
            case .shortcuts: "keyboard"
            case .privacy: "hand.raised"
            case .about: "info.circle"
            }
        }
    }

    private let actions: SettingsActions

    init(store: SettingsStore, model: SettingsModel, actions: SettingsActions) {
        self.actions = actions
        super.init(nibName: nil, bundle: nil)
        // The controller installs the window's toolbar itself once it is the
        // window's content view controller.
        tabStyle = .toolbar
        for tab in Tab.allCases {
            let controller: NSViewController
            switch tab {
            case .general: controller = page(GeneralSettingsView(store: store))
            case .shortcuts: controller = page(HotKeySettingsView(store: store, model: model, actions: actions))
            case .privacy: controller = page(PrivacySettingsView(store: store, model: model, actions: actions))
            case .about: controller = page(AboutSettingsView(store: store, model: model, actions: actions))
            }
            // The title bar reads the page name, the way System Settings does.
            controller.title = tab.label
            let item = NSTabViewItem(viewController: controller)
            item.label = tab.label
            item.image = NSImage(systemSymbolName: tab.symbol, accessibilityDescription: nil)
            addTabViewItem(item)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    func select(_ tab: Tab) {
        selectedTabViewItemIndex = tab.rawValue
    }

    /// The window has nothing to size itself to before a page has been laid
    /// out, so the first page is measured here and the first reported content
    /// size settles the rest.
    var initialContentSize: NSSize {
        let height = tabViewItems[Tab.general.rawValue].viewController?.view.fittingSize.height ?? 0
        return NSSize(width: ChromeTheme.windowWidth, height: height)
    }

    override func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        super.tabView(tabView, didSelect: tabViewItem)
        // Leaving the Shortcuts page no longer takes the field out of the view
        // hierarchy, so nothing else ends a capture that is still running: the
        // global chords would stay unregistered and the system's own Cmd-Tab,
        // borrowed for the capture, would stay switched off. Idempotent.
        actions.setRecording(false)
        resize(to: tabViewItem?.viewController?.preferredContentSize ?? .zero)
    }

    /// A page that grows in place — Privacy gains a row per denied browser —
    /// would otherwise stay clipped until the next tab switch.
    override func preferredContentSizeDidChange(for viewController: NSViewController) {
        super.preferredContentSizeDidChange(for: viewController)
        guard tabViewItems.indices.contains(selectedTabViewItemIndex),
              tabViewItems[selectedTabViewItemIndex].viewController === viewController else { return }
        resize(to: viewController.preferredContentSize)
    }

    private func page(_ view: some View) -> NSViewController {
        let controller = NSHostingController(rootView: view)
        controller.sizingOptions = [.preferredContentSize]
        return controller
    }

    private func resize(to size: NSSize) {
        // Child views load lazily, so a page that has never been shown reports
        // nothing; without this the window collapses on the first switch to it.
        guard size.height > 0, let window = view.window else { return }
        var frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: size))
        frame.origin = window.frame.origin
        // Preference windows grow downwards; the title bar stays put.
        frame.origin.y += window.frame.height - frame.height
        guard frame != window.frame else { return }
        window.setFrame(frame, display: true, animate: true)
    }
}
