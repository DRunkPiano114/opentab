import AppKit
import OpenTabCore
import OpenTabScript
import os

/// Decides whether a browser's tabs may be read right now. Nothing here
/// prompts from a refresh path; the consent dialog is reached only through
/// the guided step below, and only once per browser.
@MainActor
protocol AutomationGate: AnyObject {
    func mayReadTabs(of app: AppInfo) async -> Bool
    /// A read or activation came back refused (`-1743` / `-1744`).
    func noteRefusal(of app: AppInfo)
    /// Browsers listed as windows only because Apple Events were refused.
    var deniedBundleIDs: Set<String> { get }
    /// Browsers listed as windows only because the permission check itself
    /// did not answer - a wedged target times it out. Not a refusal, and kept
    /// apart from one so a diagnostic can tell them apart.
    var unavailableBundleIDs: Set<String> { get }
    var onChange: (@MainActor () -> Void)? { get set }
}

/// The real gate over `AutomationPermission`.
///
/// `-1744` cannot say whether the user was ever asked, so the request log is
/// the only memory of that. A browser never asked about is listed as windows
/// only until the guided step runs; that step is entered from onboarding or
/// from the status menu, never from a refresh: the consent dialog must not
/// appear while the user is switching windows, and a modal must not run
/// under the coordinator's event loop. A browser asked about and still
/// undetermined, or refused, stays windows only until the user re-enables it
/// from the Automation pane (which exists only after that first request).
@MainActor
final class AutomationGateKeeper: AutomationGate {
    var onChange: (@MainActor () -> Void)?
    /// The guided request ended in a grant; the browser's tabs can be read.
    var onAuthorized: (@MainActor (AppInfo) -> Void)?
    /// How long a refusal is trusted before the grant is checked again. Each
    /// check costs a thread that may hang, so the cadence is slow; the
    /// status-menu action forces a recheck.
    var recheckInterval: Duration = .seconds(300)

    private(set) var deniedBundleIDs: Set<String> = [] {
        didSet { if deniedBundleIDs != oldValue { onChange?() } }
    }

    private(set) var unavailableBundleIDs: Set<String> = [] {
        didSet { if unavailableBundleIDs != oldValue { onChange?() } }
    }

    private struct Verdict {
        let status: AutomationStatus
        let at: ContinuousClock.Instant
    }

    private let status: @Sendable (String) async -> AutomationStatus
    private let request: @Sendable (String) async -> AutomationStatus
    private let requestLog: any AutomationRequestLog
    /// Shows the explanatory step and returns whether the user agreed to be
    /// asked by the system.
    private let guide: @MainActor (AppInfo) async -> Bool
    private var verdicts: [String: Verdict] = [:]
    private var prompting = false
    private let log = Log.make("automation")

    convenience init(permission: AutomationPermission = AutomationPermission(),
                     requestLog: any AutomationRequestLog = DefaultsAutomationRequestLog(),
                     guide: @escaping @MainActor (AppInfo) async -> Bool = AutomationGateKeeper.presentGuide) {
        self.init(status: { await permission.status(of: $0) }, request: { await permission.request(for: $0) },
                  requestLog: requestLog, guide: guide)
    }

    init(status: @escaping @Sendable (String) async -> AutomationStatus,
         request: @escaping @Sendable (String) async -> AutomationStatus,
         requestLog: any AutomationRequestLog, guide: @escaping @MainActor (AppInfo) async -> Bool) {
        self.status = status
        self.request = request
        self.requestLog = requestLog
        self.guide = guide
    }

    func mayReadTabs(of app: AppInfo) async -> Bool {
        let bundleID = app.bundleID
        if let verdict = verdicts[bundleID] {
            if verdict.status == .authorized { return true }
            if ContinuousClock.now - verdict.at < recheckInterval { return false }
        }
        let status = await status(bundleID)
        switch status {
        case .authorized:
            record(.authorized, for: bundleID)
            return true
        case .denied, .undetermined:
            record(status, for: bundleID)
            return false
        case .targetNotRunning:
            return false
        case .timedOut, .failed:
            // The check did not answer, which says nothing about consent: a
            // wedged browser times it out. Its tabs stay unread until the
            // recheck, and the browser is reported as unavailable, not denied.
            log.notice("automation status bundle=\(bundleID, privacy: .public) \(String(describing: status), privacy: .public)")
            record(status, for: bundleID)
            return false
        }
    }

    func noteRefusal(of app: AppInfo) {
        record(.denied, for: app.bundleID)
    }

    /// Browsers listed as windows only that have never been asked: the
    /// guided request can still be offered for them.
    var awaitingRequest: Set<String> {
        Set(verdicts.filter { $0.value.status == .undetermined && !requestLog.hasRequested($0.key) }.map(\.key))
    }

    /// The onboarding step for the browsers running now, one at
    /// a time, and the status-menu action for a browser that arrived later.
    /// Our own explanation comes first, then the system prompt, so the
    /// consent dialog never appears out of nowhere.
    func requestThroughGuide(_ app: AppInfo) async {
        let bundleID = app.bundleID
        guard !bundleID.isEmpty, !requestLog.hasRequested(bundleID), !prompting else { return }
        prompting = true
        defer { prompting = false }
        guard await guide(app) else {
            log.notice("automation guide declined bundle=\(bundleID, privacy: .public)")
            return
        }
        let status = await request(bundleID)
        log.notice("automation requested bundle=\(bundleID, privacy: .public) status=\(String(describing: status), privacy: .public)")
        switch status {
        case .authorized:
            record(.authorized, for: bundleID)
            onAuthorized?(app)
        case .denied, .undetermined:
            record(.denied, for: bundleID)
        case .targetNotRunning, .timedOut, .failed:
            break
        }
    }

    /// The status-menu action: opens the Automation pane and forgets the
    /// cached refusals so the next read notices a change of heart.
    func openSettings() {
        NSWorkspace.shared.open(AutomationSettings.automationPane)
        verdicts = verdicts.filter { $0.value.status == .authorized }
    }

    private func record(_ status: AutomationStatus, for bundleID: String) {
        verdicts[bundleID] = Verdict(status: status, at: .now)
        switch status {
        case .authorized, .targetNotRunning:
            deniedBundleIDs.remove(bundleID)
            unavailableBundleIDs.remove(bundleID)
        case .timedOut, .failed:
            deniedBundleIDs.remove(bundleID)
            unavailableBundleIDs.insert(bundleID)
        case .denied, .undetermined:
            unavailableBundleIDs.remove(bundleID)
            deniedBundleIDs.insert(bundleID)
        }
    }

    private static func presentGuide(_ app: AppInfo) async -> Bool {
        let alert = NSAlert()
        alert.messageText = "List tabs from \(app.localizedName)?"
        alert.informativeText = """
            OpenTab can show the tabs of each \(app.localizedName) window. macOS will ask you to allow \
            OpenTab to control \(app.localizedName); without that permission its windows are listed \
            without tabs.
            """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Continue")
        alert.addButton(withTitle: "Not Now")
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn
    }
}
