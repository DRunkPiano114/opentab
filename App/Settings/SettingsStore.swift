import AppKit
import Observation
import OpenTabCore
import ServiceManagement

enum PanelPosition: String, CaseIterable, Sendable {
    case left, centre, right

    var label: String {
        switch self {
        case .left: "Left"
        case .centre: "Centre"
        case .right: "Right"
        }
    }
}

enum PanelTextSize: String, CaseIterable, Sendable {
    case small, medium, large

    /// Multiplies the list's font sizes. The row box stays 46pt: the largest
    /// scale still leaves both lines inside it, so nothing reflows.
    var scale: CGFloat {
        switch self {
        case .small: 0.9
        case .medium: 1.0
        case .large: 1.15
        }
    }

    var label: String {
        switch self {
        case .small: "Small"
        case .medium: "Medium"
        case .large: "Large"
        }
    }
}

/// Which setting changed. The owner applies exactly that one, so nothing has
/// to be idempotent and nothing is re-applied behind the user's back.
enum Setting: Sendable {
    case launchAtLogin
    case showMenuBarIcon
    case appearance
    case sortMode
    case includesPrivateTabs
    case remoteFavicons
    case cmdTabTakeover
    case hotKeys
    case ignoreTitlePatterns
}

/// The settings surface. Reads and writes `UserDefaults` under the keys in
/// `DefaultsKey`, and reports each change so the running app can apply it
/// without a relaunch.
@MainActor
@Observable
final class SettingsStore {
    /// Called after a value has been written, with what changed.
    @ObservationIgnored var onChange: (@MainActor (Setting) -> Void)?

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let log = Log.make("settings")

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        launchesAtLogin = SMAppService.mainApp.status == .enabled
        showMenuBarIcon = defaults.object(forKey: DefaultsKey.showMenuBarIcon) as? Bool ?? true
        panelPosition = PanelPosition(rawValue: defaults.string(forKey: DefaultsKey.panelPosition) ?? "") ?? .left
        textSize = PanelTextSize(rawValue: defaults.string(forKey: DefaultsKey.panelTextSize) ?? "") ?? .medium
        widePanel = defaults.bool(forKey: DefaultsKey.panelWide)
        isAlphabetical = defaults.string(forKey: DefaultsKey.sortMode) == "alphabetical"
        includesPrivateTabs = defaults.bool(forKey: DefaultsKey.includesPrivateTabs)
        remoteFavicons = defaults.bool(forKey: DefaultsKey.remoteFavicons)
        cmdTabTakeover = defaults.bool(forKey: DefaultsKey.cmdTabTakeover)
        mainHotKey = HotKeyBinding(stored: defaults.object(forKey: DefaultsKey.mainHotKey)) ?? .mainDefault
        reverseHotKey = HotKeyBinding(stored: defaults.object(forKey: DefaultsKey.reverseHotKey)) ?? .reverseDefault
        searchHotKey = HotKeyBinding(stored: defaults.object(forKey: DefaultsKey.searchHotKey)) ?? .searchDefault
        ignoreTitlePatterns = defaults.stringArray(forKey: DefaultsKey.ignoreTitlePatterns) ?? []
    }

    // MARK: General

    /// `SMAppService` owns this state; there is no default of our own that
    /// could disagree with it. Mirrored into a stored property so the toggle
    /// can show a registration that failed as not having happened.
    var launchesAtLogin: Bool {
        didSet {
            guard launchesAtLogin != oldValue else { return }
            do {
                if launchesAtLogin {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                log.error("launch at login \(self.launchesAtLogin, privacy: .public) failed: \(String(describing: error), privacy: .public)")
                launchesAtLogin = SMAppService.mainApp.status == .enabled
                return
            }
            onChange?(.launchAtLogin)
        }
    }

    var showMenuBarIcon: Bool {
        didSet { write(showMenuBarIcon, DefaultsKey.showMenuBarIcon, .showMenuBarIcon, from: oldValue) }
    }

    var panelPosition: PanelPosition {
        didSet { write(panelPosition.rawValue, DefaultsKey.panelPosition, .appearance, from: oldValue.rawValue) }
    }

    var textSize: PanelTextSize {
        didSet { write(textSize.rawValue, DefaultsKey.panelTextSize, .appearance, from: oldValue.rawValue) }
    }

    var widePanel: Bool {
        didSet { write(widePanel, DefaultsKey.panelWide, .appearance, from: oldValue) }
    }

    var isAlphabetical: Bool {
        didSet { write(isAlphabetical ? "alphabetical" : "recency", DefaultsKey.sortMode, .sortMode,
                       from: oldValue ? "alphabetical" : "recency") }
    }

    var sortMode: SortMode { isAlphabetical ? .alphabetical : .recency }

    // MARK: Privacy

    var includesPrivateTabs: Bool {
        didSet { write(includesPrivateTabs, DefaultsKey.includesPrivateTabs, .includesPrivateTabs, from: oldValue) }
    }

    /// Written here and read by `FaviconStore`, which is also given the new
    /// value so it can drop the misses it cached while the tier was off.
    var remoteFavicons: Bool {
        didSet { write(remoteFavicons, DefaultsKey.remoteFavicons, .remoteFavicons, from: oldValue) }
    }

    var ignoreTitlePatterns: [String] {
        didSet {
            guard ignoreTitlePatterns != oldValue else { return }
            defaults.set(ignoreTitlePatterns, forKey: DefaultsKey.ignoreTitlePatterns)
            onChange?(.ignoreTitlePatterns)
        }
    }

    /// Patterns that do not compile, so the settings window can say which
    /// line is wrong instead of silently dropping it (`IgnoreRules` compiles
    /// with `try?`).
    static func invalidPatterns(in patterns: [String]) -> [String] {
        patterns.filter { (try? NSRegularExpression(pattern: $0)) == nil }
    }

    // MARK: Hotkeys

    var cmdTabTakeover: Bool {
        didSet { write(cmdTabTakeover, DefaultsKey.cmdTabTakeover, .cmdTabTakeover, from: oldValue) }
    }

    var mainHotKey: HotKeyBinding {
        didSet { writeHotKey(mainHotKey, DefaultsKey.mainHotKey, from: oldValue) }
    }

    var reverseHotKey: HotKeyBinding {
        didSet { writeHotKey(reverseHotKey, DefaultsKey.reverseHotKey, from: oldValue) }
    }

    var searchHotKey: HotKeyBinding {
        didSet { writeHotKey(searchHotKey, DefaultsKey.searchHotKey, from: oldValue) }
    }

    func resetHotKeys() {
        mainHotKey = .mainDefault
        reverseHotKey = .reverseDefault
        searchHotKey = .searchDefault
    }

    // MARK: Onboarding

    var hasCompletedOnboarding: Bool {
        get { defaults.bool(forKey: DefaultsKey.onboardingCompleted) }
        set { defaults.set(newValue, forKey: DefaultsKey.onboardingCompleted) }
    }

    /// Whether any browser has been through the consent prompt. The system's
    /// Automation pane does not exist before that, so the deep link to it is
    /// only offered once this is true.
    var hasRequestedAutomation: Bool {
        !(defaults.stringArray(forKey: DefaultsKey.automationRequested) ?? []).isEmpty
    }

    // MARK: Writing

    private func write<Value: Equatable>(_ value: Value, _ key: String, _ setting: Setting, from oldValue: Value) {
        guard value != oldValue else { return }
        defaults.set(value, forKey: key)
        log.notice("setting \(key, privacy: .public) changed")
        onChange?(setting)
    }

    private func writeHotKey(_ binding: HotKeyBinding, _ key: String, from oldValue: HotKeyBinding) {
        guard binding != oldValue else { return }
        defaults.set(binding.stored, forKey: key)
        log.notice("setting \(key, privacy: .public) changed")
        onChange?(.hotKeys)
    }
}
