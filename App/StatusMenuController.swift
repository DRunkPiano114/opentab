import AppKit
import Carbon
import OpenTabCore

/// Menu bar item. The menu is a short list of verbs, rebuilt from the spec
/// every time it opens; anything degraded is folded into one attention row at
/// the top and marked on the status item itself.
@MainActor
final class StatusMenuController: NSObject, NSMenuDelegate {
    var accessibilityGranted = false { didSet { refreshBadge() } }
    /// Both copies answer the same chord, so both open a panel.
    var otherInstanceRunning = false { didSet { refreshBadge() } }
    /// The bound chord wants the window-server write and this Mac has none.
    var takeoverUnavailable = false { didSet { refreshBadge() } }
    var windowIDBridgeAvailable = true { didSet { refreshBadge() } }
    var secureInputActive = false { didSet { refreshBadge() } }
    /// Display names of browsers listed as windows only because Apple
    /// Events were refused.
    var tabsUnavailable: [String] = [] { didSet { refreshBadge() } }
    /// Browsers never asked for Apple Events consent. Nothing has gone wrong
    /// yet, so this is not one of the attention row's conditions.
    var tabsAwaitingRequest: [String] = []
    /// Whether the running copy has an updater at all; the development copy
    /// has none, and an item that cannot work is worse than no item.
    var hasUpdater = false
    /// The updater's own gate: false while a check or an install is running.
    var canCheckForUpdates = true
    /// Hiding the icon is a setting; the settings window stays reachable by
    /// launching the app again, which reopens it.
    var isIconVisible = true { didSet { item.isVisible = isIconVisible } }
    /// Read when the menu opens, so the shortcut drawn is the one bound now
    /// rather than the one bound when the menu was last built.
    var boundChords: () -> [HotKeyBinding] = { [] }

    var onOpenSwitcher: (() -> Void)?
    var onSearchWindows: (() -> Void)?
    var onCheckForUpdates: (() -> Void)?
    var onOpenSettings: (() -> Void)?
    var onOpenAutomationSettings: (() -> Void)?
    var onOpenShortcutsTab: (() -> Void)?
    var onOpenPrivacyTab: (() -> Void)?

    private let item: NSStatusItem
    private let menu = NSMenu()

    override init() {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        item.button?.image = NSImage(systemSymbolName: "macwindow.on.rectangle", accessibilityDescription: nil)
        item.button?.imagePosition = .imageLeading
        // Off, so that every `isEnabled` below is honoured rather than
        // silently overruled by menu validation.
        menu.autoenablesItems = false
        menu.delegate = self
        item.menu = menu
        refreshBadge()
    }

    private var inputs: StatusMenuSpec.Inputs {
        var inputs = StatusMenuSpec.Inputs()
        inputs.accessibilityGranted = accessibilityGranted
        inputs.otherInstanceRunning = otherInstanceRunning
        inputs.takeoverUnavailable = takeoverUnavailable
        inputs.windowIDBridgeAvailable = windowIDBridgeAvailable
        inputs.secureInputActive = secureInputActive
        inputs.tabsUnavailable = tabsUnavailable
        inputs.tabsAwaitingRequest = tabsAwaitingRequest
        inputs.hasUpdater = hasUpdater
        inputs.canCheckForUpdates = canCheckForUpdates
        let chords = boundChords()
        inputs.mainShortcut = chords.first.flatMap(Self.keyEquivalent)
        inputs.searchShortcut = chords.count > 2 ? Self.keyEquivalent(chords[2]) : nil
        return inputs
    }

    /// The populate hook. Rebuilding in `menuWillOpen` instead is what drops
    /// items under fast repeated opens: structural changes are forbidden
    /// there.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        for spec in StatusMenuSpec.items(inputs) {
            menu.addItem(makeItem(spec))
        }
    }

    private func makeItem(_ spec: StatusMenuSpec.Item) -> NSMenuItem {
        switch spec {
        case .separator:
            return .separator()
        case let .action(action, title, keyEquivalent, isEnabled):
            let item = makeAction(action, title: title, keyEquivalent: keyEquivalent)
            item.isEnabled = isEnabled
            return item
        case let .attention(title, conditions):
            let item: NSMenuItem
            if conditions.count == 1 {
                item = makeAction(conditions[0].action, title: title, keyEquivalent: nil)
            } else {
                item = makeAction(nil, title: title, keyEquivalent: nil)
                let submenu = NSMenu()
                submenu.autoenablesItems = false
                for condition in conditions {
                    submenu.addItem(makeAction(condition.action, title: condition.title, keyEquivalent: nil))
                }
                item.submenu = submenu
            }
            // The plain title stays set: accessibility and key-equivalent
            // matching read it. The attributed one colours the dot alone, so
            // AppKit still inverts the text on the highlighted row; a
            // foreground colour on the title would stay dark there.
            item.attributedTitle = Self.markedTitle(title)
            return item
        }
    }

    private func makeAction(_ action: StatusMenuSpec.Action?, title: String,
                            keyEquivalent: StatusMenuSpec.KeyEquivalent?) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: keyEquivalent?.key ?? "")
        item.keyEquivalentModifierMask = Self.modifierMask(keyEquivalent)
        if let action {
            let (selector, target) = handler(for: action)
            item.action = selector
            item.target = target
        }
        return item
    }

    private static func modifierMask(_ keyEquivalent: StatusMenuSpec.KeyEquivalent?) -> NSEvent.ModifierFlags {
        guard let keyEquivalent else { return [] }
        var mask: NSEvent.ModifierFlags = []
        if keyEquivalent.command { mask.insert(.command) }
        if keyEquivalent.option { mask.insert(.option) }
        if keyEquivalent.shift { mask.insert(.shift) }
        if keyEquivalent.control { mask.insert(.control) }
        return mask
    }

    /// The chord as a menu key equivalent. In a status-item menu this fires
    /// only while the menu is open; the chord's real delivery stays with the
    /// Carbon registration.
    private static func keyEquivalent(_ binding: HotKeyBinding) -> StatusMenuSpec.KeyEquivalent? {
        let key: String
        if binding.keyCode == UInt32(kVK_Tab) {
            key = "\t"
        } else {
            let label = KeyCodeNames.label(for: binding.keyCode)
            guard label.count == 1 else { return nil }
            // An uppercase letter would draw a Shift glyph the chord has not
            // got.
            key = label.lowercased()
        }
        return StatusMenuSpec.KeyEquivalent(key: key,
                                            command: binding.carbonModifiers & UInt32(cmdKey) != 0,
                                            option: binding.carbonModifiers & UInt32(optionKey) != 0,
                                            shift: binding.carbonModifiers & UInt32(shiftKey) != 0,
                                            control: binding.carbonModifiers & UInt32(controlKey) != 0)
    }

    private static func markedTitle(_ title: String) -> NSAttributedString {
        let font = NSFont.menuFont(ofSize: 0)
        let marked = NSMutableAttributedString(string: "\u{25CF}",
                                               attributes: [.font: font, .foregroundColor: NSColor.systemOrange])
        marked.append(NSAttributedString(string: "\u{2009}\(title)", attributes: [.font: font]))
        return marked
    }

    /// The same marker the attention row carries, on the item itself. The
    /// icon stays a template symbol: a composite image would lose the menu
    /// bar's own tinting.
    private func refreshBadge() {
        guard let button = item.button else { return }
        let degraded = !StatusMenuSpec.conditions(inputs).isEmpty
        if degraded {
            button.attributedTitle = NSAttributedString(string: "\u{25CF}",
                                                        attributes: [.foregroundColor: NSColor.systemOrange])
        } else {
            button.title = ""
        }
        button.setAccessibilityLabel(degraded ? "OpenTab, needs attention" : "OpenTab")
    }

    private func handler(for action: StatusMenuSpec.Action) -> (Selector, AnyObject?) {
        switch action {
        case .openSwitcher: (#selector(openSwitcher), self)
        case .searchWindows: (#selector(searchWindows), self)
        case .checkForUpdates: (#selector(checkForUpdates), self)
        case .settings: (#selector(openSettings), self)
        case .quit: (#selector(NSApplication.terminate(_:)), NSApp)
        case .openAccessibilitySettings: (#selector(openAccessibilitySettings), self)
        case .openAutomationSettings: (#selector(openAutomationSettings), self)
        case .openShortcutsTab: (#selector(openShortcutsTab), self)
        case .openPrivacyTab: (#selector(openPrivacyTab), self)
        }
    }

    @objc private func openSwitcher() {
        onOpenSwitcher?()
    }

    @objc private func searchWindows() {
        onSearchWindows?()
    }

    @objc private func checkForUpdates() {
        onCheckForUpdates?()
    }

    @objc private func openSettings() {
        onOpenSettings?()
    }

    @objc private func openAccessibilitySettings() {
        NSWorkspace.shared.open(SystemSettingsLinks.accessibility)
    }

    @objc private func openAutomationSettings() {
        onOpenAutomationSettings?()
    }

    @objc private func openShortcutsTab() {
        onOpenShortcutsTab?()
    }

    @objc private func openPrivacyTab() {
        onOpenPrivacyTab?()
    }
}
