import AppKit
import Observation

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
    var safariCacheGranted = false
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
    var rebuildIndex: () -> Void = {}
    var openAccessibilitySettings: () -> Void = {}
    var openAutomationSettings: () -> Void = {}
    /// Runs the guided Apple Events request for one browser. Never reached
    /// from a refresh path (packet §5).
    var requestAutomation: (String) -> Void = { _ in }
    var grantSafariCacheAccess: () -> Void = {}
    var refreshHealth: () -> Void = {}
    /// True while a shortcut field is capturing; the global chords are
    /// released so the field can see them.
    var setRecording: (Bool) -> Void = { _ in }
    /// Whether the Automation pane exists yet: it does not until some app has
    /// asked for Apple Events at least once.
    var automationPaneExists: () -> Bool = { false }
}
