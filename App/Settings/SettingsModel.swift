import AppKit
import Observation
import OpenTabWS

/// Live state the settings window shows but does not own: permission
/// verdicts, degraded modes and the health read-out. The app delegate keeps
/// it current, the same way it keeps the status menu current.
@MainActor
@Observable
final class SettingsModel {
    var accessibilityGranted = false
    var windowIDBridgeAvailable = true
    var secureInputActive = false
    var cmdTabTakeoverAvailable = true
    /// The app's current verdict on the Cmd-Tab takeover.
    var takeoverPolicy: TakeoverPolicy = .notWanted
    var safariCacheGranted = false
    /// Whether this copy has an updater at all; the development copy has none.
    var updatesAvailable = false
    /// Set while another copy of OpenTab is running, which makes every press
    /// of the shortcut open two panels.
    var otherInstance: String?
    /// Browsers listed as windows only because Apple Events were refused.
    var tabsUnavailable: [String] = []
    /// Browsers that have never been asked; the row offers the guided request.
    var tabsAwaitingRequest: [(bundleID: String, name: String)] = []
    var health = HealthMonitor.Snapshot(footprintBytes: 0, peakFootprintBytes: 0, entryCount: 0, uptime: .zero)
}

/// What the settings window can ask the app to do. Closures rather than a
/// reference to the delegate so the window can be driven from a test.
@MainActor
struct SettingsActions {
    var openAccessibilitySettings: () -> Void = {}
    var openAutomationSettings: () -> Void = {}
    /// Runs the guided Apple Events request for one browser. Never reached
    /// from a refresh path.
    var requestAutomation: (String) -> Void = { _ in }
    var grantSafariCacheAccess: () -> Void = {}
    var refreshHealth: () -> Void = {}
    /// Asks the updater to look now. Inert in a build that has no updater,
    /// where the About page draws no update controls either.
    var checkForUpdates: () -> Void = {}
    /// True while a shortcut field is capturing; the global chords are
    /// released so the field can see them.
    var setRecording: (Bool) -> Void = { _ in }
    /// Whether the Automation pane exists yet: it does not until some app has
    /// asked for Apple Events at least once.
    var automationPaneExists: () -> Bool = { false }
}
