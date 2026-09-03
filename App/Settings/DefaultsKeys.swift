import Foundation
import OpenTabWS

/// Every `UserDefaults` key the app reads, in one place.
///
/// Keys under "owned elsewhere" belong to a component that reads them
/// directly; they are re-exported here so the whole persisted surface can be
/// seen at once, and so a rename cannot leave the settings window writing to
/// a key nobody reads.
enum DefaultsKey {
    static let showMenuBarIcon = "general.showMenuBarIcon"
    static let panelPosition = "panel.position"
    static let panelTextSize = "panel.textSize"
    static let panelWide = "panel.wide"
    static let sortMode = "list.sortMode"
    static let mainHotKey = "hotkey.main"
    static let reverseHotKey = "hotkey.reverse"
    static let searchHotKey = "hotkey.search"
    static let onboardingCompleted = "onboarding.completed"

    // Owned elsewhere.

    /// `AppDelegate`, `TabStore.Configuration`, `TabProviderRegistry` (L16).
    static let includesPrivateTabs = "tabs.includePrivate"
    /// `IgnoreRules`. User-authored regexes, the one sanctioned exception to
    /// L3's "never match on display strings".
    static let ignoreTitlePatterns = "ignoreTitlePatterns"
    /// `FaviconStore.remoteLookupDefaultsKey`.
    static let remoteFavicons = "favicons.allowRemoteLookup"
    /// `FaviconSafariBookmark.defaultsKey`, a security-scoped bookmark.
    static let safariFaviconBookmark = "favicons.safariBookmark"
    /// `CmdTabTakeover.defaultsKey`, whose own constant is main-actor
    /// isolated. `SettingsKeyTests` asserts the two agree.
    static let cmdTabTakeover = "ws.cmdTabTakeover"
    /// `DefaultsAutomationRequestLog`. Non-empty means some browser has been
    /// put through the consent prompt, which is when the Automation pane
    /// starts to exist.
    static let automationRequested = "automation.requested"
    /// `OffSpaceConfiguration`. Diagnostic overrides with no settings UI.
    static let scanMaxElementID = OffSpaceConfiguration.maxElementIDKey
    static let scanBudgetMilliseconds = OffSpaceConfiguration.budgetMillisecondsKey
    /// `CmdTabRecovery`. A session marker, not a setting.
    static let cmdTabOriginalState = "ws.cmdTab.originalState"
}
