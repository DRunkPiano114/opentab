import AppKit

/// Menu bar item. Every degraded mode is visible here (L10): a marker in the
/// status title and a disabled explanatory item.
@MainActor
final class StatusMenuController: NSObject {
    var accessibilityGranted = false { didSet { rebuild() } }
    var windowIDBridgeAvailable = true { didSet { rebuild() } }
    var secureInputActive = false { didSet { rebuild() } }
    /// Display names of browsers listed as windows only because Apple
    /// Events were refused.
    var tabsUnavailable: [String] = [] { didSet { rebuild() } }
    /// Browsers never asked for Apple Events consent; the item runs the
    /// guided request.
    var tabsAwaitingRequest: [(bundleID: String, name: String)] = [] { didSet { rebuild() } }
    /// Favicon lookups that leave the machine. Off unless the user turns it
    /// on, and the menu says what it costs.
    var faviconRemoteEnabled = false { didSet { rebuild() } }
    var faviconRemoteDisclosure = "" { didSet { rebuild() } }
    /// Whether the user has picked ~/Library/Safari, which is the only way to
    /// read Safari's favicon cache without Full Disk Access.
    var safariCacheGranted = false { didSet { rebuild() } }
    /// Hiding the icon is a setting; the settings window stays reachable by
    /// launching the app again, which reopens it.
    var isIconVisible = true { didSet { item.isVisible = isIconVisible } }
    var onOpenSettings: (() -> Void)?
    var onToggleFaviconRemote: ((Bool) -> Void)?
    var onGrantSafariCache: (() -> Void)?
    var onRebuildIndex: (() -> Void)?
    var onOpenAutomationSettings: (() -> Void)?
    var onEnableTabs: ((String) -> Void)?

    private let item: NSStatusItem

    override init() {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        item.button?.image = NSImage(systemSymbolName: "macwindow.on.rectangle", accessibilityDescription: "OpenTab")
        item.button?.imagePosition = .imageLeading
        rebuild()
    }

    private func rebuild() {
        let degraded = !accessibilityGranted || !windowIDBridgeAvailable || secureInputActive || !tabsUnavailable.isEmpty
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
        if !tabsUnavailable.isEmpty {
            for name in tabsUnavailable {
                menu.addItem(disabled("\(name): tabs unavailable (Automation not allowed)"))
            }
            let open = NSMenuItem(title: "Open Automation Settings…",
                                  action: #selector(openAutomationSettings), keyEquivalent: "")
            open.target = self
            menu.addItem(open)
        }
        for browser in tabsAwaitingRequest {
            let enable = NSMenuItem(title: "Enable tabs for \(browser.name)…",
                                    action: #selector(enableTabs(_:)), keyEquivalent: "")
            enable.target = self
            enable.representedObject = browser.bundleID
            menu.addItem(enable)
        }
        menu.addItem(.separator())
        for item in faviconItems() { menu.addItem(item) }
        menu.addItem(.separator())

        let rebuildItem = NSMenuItem(title: "Rebuild Index", action: #selector(rebuildIndex), keyEquivalent: "")
        rebuildItem.target = self
        rebuildItem.toolTip = "Drop the whole list and read every window again."
        menu.addItem(rebuildItem)
        let settings = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit OpenTab", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp
        menu.addItem(quit)

        item.menu = menu
    }

    /// The favicon section. Tab rows fall back to the app icon when no local
    /// cache has the site, so both items below are conveniences, not
    /// requirements.
    private func faviconItems() -> [NSMenuItem] {
        var items: [NSMenuItem] = [disabled("Favicons")]
        if safariCacheGranted {
            items.append(disabled("  Safari cache: readable"))
        } else {
            let grant = NSMenuItem(title: "  Allow Reading Safari's Favicon Cache…",
                                   action: #selector(grantSafariCache), keyEquivalent: "")
            grant.target = self
            items.append(grant)
        }
        let remote = NSMenuItem(title: "  Look Up Missing Favicons on Google",
                                action: #selector(toggleFaviconRemote), keyEquivalent: "")
        remote.target = self
        remote.state = faviconRemoteEnabled ? .on : .off
        items.append(remote)
        if !faviconRemoteDisclosure.isEmpty {
            items.append(disabled("  \(faviconRemoteDisclosure)"))
        }
        return items
    }

    private func disabled(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    @objc private func openAccessibilitySettings() {
        NSWorkspace.shared.open(SystemSettingsLinks.accessibility)
    }

    @objc private func openSettings() {
        onOpenSettings?()
    }

    @objc private func rebuildIndex() {
        onRebuildIndex?()
    }

    @objc private func openAutomationSettings() {
        onOpenAutomationSettings?()
    }

    @objc private func toggleFaviconRemote() {
        onToggleFaviconRemote?(!faviconRemoteEnabled)
    }

    @objc private func grantSafariCache() {
        onGrantSafariCache?()
    }

    @objc private func enableTabs(_ sender: NSMenuItem) {
        guard let bundleID = sender.representedObject as? String else { return }
        onEnableTabs?(bundleID)
    }
}
