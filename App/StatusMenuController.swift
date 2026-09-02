import AppKit

/// Menu bar item. Every degraded mode is visible here (L10): a marker in the
/// status title and a disabled explanatory item.
@MainActor
final class StatusMenuController: NSObject {
    var accessibilityGranted = false { didSet { rebuild() } }
    var windowIDBridgeAvailable = true { didSet { rebuild() } }
    var secureInputActive = false { didSet { rebuild() } }
    var onRebuildIndex: (() -> Void)?

    private static let accessibilitySettingsURL =
        URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!

    private let item: NSStatusItem

    override init() {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        item.button?.image = NSImage(systemSymbolName: "macwindow.on.rectangle", accessibilityDescription: "OpenTab")
        item.button?.imagePosition = .imageLeading
        rebuild()
    }

    private func rebuild() {
        let degraded = !accessibilityGranted || !windowIDBridgeAvailable || secureInputActive
        item.button?.title = degraded ? "⚠︎" : ""

        let menu = NSMenu()
        menu.autoenablesItems = false

        if accessibilityGranted {
            menu.addItem(disabled("Accessibility: granted"))
        } else {
            let open = NSMenuItem(title: "Accessibility: NOT granted — Open System Settings…",
                                  action: #selector(openAccessibilitySettings), keyEquivalent: "")
            open.target = self
            menu.addItem(open)
        }
        if !windowIDBridgeAvailable {
            menu.addItem(disabled("Window ID bridge unavailable (degraded)"))
        }
        if secureInputActive {
            menu.addItem(disabled("Secure Input active: hotkeys may not work"))
        }
        menu.addItem(.separator())

        let rebuildItem = NSMenuItem(title: "Rebuild Index", action: #selector(rebuildIndex), keyEquivalent: "")
        rebuildItem.target = self
        menu.addItem(rebuildItem)
        menu.addItem(disabled("Settings…"))
        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit OpenTab", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp
        menu.addItem(quit)

        item.menu = menu
    }

    private func disabled(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    @objc private func openAccessibilitySettings() {
        NSWorkspace.shared.open(Self.accessibilitySettingsURL)
    }

    @objc private func rebuildIndex() {
        onRebuildIndex?()
    }
}
