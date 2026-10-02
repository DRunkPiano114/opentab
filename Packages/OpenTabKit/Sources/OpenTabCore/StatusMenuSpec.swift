import Foundation

/// What the menu bar menu contains, as data.
///
/// The menu itself is AppKit and can only be checked by a human opening it,
/// so everything decidable — the order, the grouping, which rows appear while
/// something is degraded — lives here instead, where the pure-logic suite
/// reaches it.
public enum StatusMenuSpec {
    /// A menu key equivalent, as the four modifiers AppKit draws plus the
    /// character itself.
    public struct KeyEquivalent: Equatable, Sendable {
        /// One character: `"\t"` for Tab, `"l"` for L. Uppercase implies Shift
        /// in what AppKit draws, so callers pass the lowercased character.
        public var key: String
        public var command: Bool
        public var option: Bool
        public var shift: Bool
        public var control: Bool

        public init(key: String, command: Bool = false, option: Bool = false,
                    shift: Bool = false, control: Bool = false) {
            self.key = key
            self.command = command
            self.option = option
            self.shift = shift
            self.control = control
        }
    }

    public enum Action: Equatable, Sendable {
        case openSwitcher, searchWindows, about, checkForUpdates, restartToUpdate, settings, quit
        case openAccessibilitySettings, openAutomationSettings, openShortcutsTab, openPrivacyTab
    }

    /// One thing that is wrong, and where the user fixes it.
    public struct Condition: Equatable, Sendable {
        public var title: String
        public var action: Action
    }

    public enum Item: Equatable, Sendable {
        case action(Action, title: String, keyEquivalent: KeyEquivalent?, isEnabled: Bool)
        case attention(title: String, conditions: [Condition])
        case separator
    }

    /// An update a background check found and left for the user to open from
    /// the menu.
    public struct WaitingUpdate: Equatable, Sendable {
        public var version: String
        /// The user has looked at the update's own window; the item stays
        /// until the update is installed or put off.
        public var seen: Bool

        public init(version: String, seen: Bool = false) {
            self.version = version
            self.seen = seen
        }
    }

    /// The mark on the status item itself.
    public enum Badge: Equatable, Sendable {
        case none
        /// Something is degraded; this wins over an update.
        case attention
        case update
    }

    /// Everything the menu depends on. Defaults describe a healthy copy, so a
    /// test names only what it is about.
    public struct Inputs: Equatable, Sendable {
        public var accessibilityGranted = true
        public var otherInstanceRunning = false
        /// The bound chord wants the window-server write and this Mac does not
        /// have it.
        public var takeoverUnavailable = false
        public var windowIDBridgeAvailable = true
        /// Browser display names, sorted by the caller.
        public var tabsUnavailable: [String] = []
        /// Browsers that have never been asked for Apple Events. Not a
        /// degradation: nothing has gone wrong yet.
        public var tabsAwaitingRequest: [String] = []
        public var mainShortcut: KeyEquivalent?
        public var searchShortcut: KeyEquivalent?
        /// Whether this copy has an updater at all.
        public var hasUpdater = false
        public var canCheckForUpdates = true
        public var waitingUpdate: WaitingUpdate?
        /// The version of an update downloaded in the background and waiting
        /// to install on quit.
        public var readyToInstall: String?

        public init() {}
    }

    /// Worst first: the attention row is titled after the first one.
    public static func conditions(_ inputs: Inputs) -> [Condition] {
        var conditions: [Condition] = []
        if !inputs.accessibilityGranted {
            conditions.append(Condition(title: "Accessibility Is Not Granted",
                                        action: .openAccessibilitySettings))
        }
        if inputs.otherInstanceRunning {
            conditions.append(Condition(title: "Another Copy of OpenTab Is Running",
                                        action: .openShortcutsTab))
        }
        if inputs.takeoverUnavailable {
            conditions.append(Condition(title: "\u{2318}\u{2009}Tab Is Not Available on This Mac",
                                        action: .openShortcutsTab))
        }
        if !inputs.windowIDBridgeAvailable {
            conditions.append(Condition(title: "Some Windows Are Matched Less Precisely",
                                        action: .openPrivacyTab))
        }
        for name in inputs.tabsUnavailable {
            conditions.append(Condition(title: "\(name) Tabs Need Automation Access",
                                        action: .openAutomationSettings))
        }
        return conditions
    }

    public static func badge(_ inputs: Inputs) -> Badge {
        if !conditions(inputs).isEmpty { return .attention }
        // Only while the waiting update's item is the one in the menu; an
        // update ready to install is something the user chose and needs no mark.
        if inputs.hasUpdater, inputs.readyToInstall == nil, let waiting = inputs.waitingUpdate, !waiting.seen {
            return .update
        }
        return .none
    }

    public static func items(_ inputs: Inputs) -> [Item] {
        var items: [Item] = []
        let conditions = conditions(inputs)
        if let worst = conditions.first {
            items.append(.attention(title: worst.title, conditions: conditions))
            items.append(.separator)
        }
        items.append(.action(.openSwitcher, title: "Open Switcher",
                             keyEquivalent: inputs.mainShortcut, isEnabled: true))
        items.append(.action(.searchWindows, title: "Search Windows",
                             keyEquivalent: inputs.searchShortcut, isEnabled: true))
        items.append(.separator)
        // About keeps this group non-empty on a copy built without an updater.
        items.append(.action(.about, title: "About OpenTab", keyEquivalent: nil, isEnabled: true))
        if inputs.hasUpdater, let ready = inputs.readyToInstall {
            // Enabled whatever the updater's gate says: holding the update
            // keeps the updater busy until it is installed.
            items.append(.action(.restartToUpdate, title: "Restart to Update to \(ready)",
                                 keyEquivalent: nil, isEnabled: true))
        } else if inputs.hasUpdater {
            // The same action brings a waiting update's window forward
            // without fetching anything again.
            let title = inputs.waitingUpdate.map { "Update Available: \($0.version)\u{2026}" }
                ?? "Check for Updates\u{2026}"
            items.append(.action(.checkForUpdates, title: title,
                                 keyEquivalent: nil, isEnabled: inputs.canCheckForUpdates))
        }
        items.append(.separator)
        items.append(.action(.settings, title: "Settings\u{2026}", keyEquivalent: nil, isEnabled: true))
        items.append(.separator)
        items.append(.action(.quit, title: "Quit", keyEquivalent: nil, isEnabled: true))
        return items
    }
}
