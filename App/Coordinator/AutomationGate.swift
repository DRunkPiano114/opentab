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
    var onChange: (@MainActor () -> Void)? { get set }
}

/// The real gate over `AutomationPermission`.
///
/// `-1744` cannot say whether the user was ever asked, so the request log is
/// the only memory of that: a browser we have asked about and that still
/// answers undetermined is treated as refused, and never asked again on its
/// own. The user re-enables it from the status menu, which deep-links to the
/// Automation pane (which exists only after that first request).
@MainActor
final class AutomationGateKeeper: AutomationGate {
    /// Whether a modal may go up now; false while the switcher is engaged.
    var promptsAllowed: () -> Bool = { true }
    var onChange: (@MainActor () -> Void)?
    /// The guided request ended in a grant; the browser's tabs can be read.
    var onAuthorized: (@MainActor (AppInfo) -> Void)?
    /// How long a refusal is trusted before the grant is checked again.
    var recheckInterval: Duration = .seconds(30)

    private(set) var deniedBundleIDs: Set<String> = [] {
        didSet { if deniedBundleIDs != oldValue { onChange?() } }
    }

    private struct Verdict {
        let status: AutomationStatus
        let at: ContinuousClock.Instant
    }

    private let permission: AutomationPermission
    private let requestLog: any AutomationRequestLog
    /// Shows the explanatory step and returns whether the user agreed to be
    /// asked by the system.
    private let guide: @MainActor (AppInfo) async -> Bool
    private var verdicts: [String: Verdict] = [:]
    /// Declined our own step this session; not asked again until relaunch.
    private var declined: Set<String> = []
    private var prompting = false
    private let log = Log.make("automation")

    init(permission: AutomationPermission = AutomationPermission(),
         requestLog: any AutomationRequestLog = DefaultsAutomationRequestLog(),
         guide: @escaping @MainActor (AppInfo) async -> Bool = AutomationGateKeeper.presentGuide) {
        self.permission = permission
        self.requestLog = requestLog
        self.guide = guide
    }

    func mayReadTabs(of app: AppInfo) async -> Bool {
        let bundleID = app.bundleID
        if let verdict = verdicts[bundleID] {
            if verdict.status == .authorized { return true }
            if ContinuousClock.now - verdict.at < recheckInterval { return false }
        }
        let status = await permission.status(of: bundleID)
        switch status {
        case .authorized:
            record(.authorized, for: bundleID)
            return true
        case .denied:
            record(.denied, for: bundleID)
            return false
        case .undetermined:
            if requestLog.hasRequested(bundleID) {
                record(.undetermined, for: bundleID)
                return false
            }
            beginGuide(for: app)
            return false
        case .targetNotRunning:
            return false
        case .timedOut, .failed:
            log.error("automation status bundle=\(bundleID, privacy: .public) \(String(describing: status), privacy: .public)")
            verdicts[bundleID] = Verdict(status: status, at: .now)
            return false
        }
    }

    func noteRefusal(of app: AppInfo) {
        record(.denied, for: app.bundleID)
    }

    /// The status-menu action: opens the Automation pane and forgets the
    /// cached refusals so the next read notices a change of heart.
    func openSettings() {
        NSWorkspace.shared.open(AutomationSettings.automationPane)
        verdicts = verdicts.filter { $0.value.status == .authorized }
        declined.removeAll()
    }

    /// The guided step (packet §5): our own explanation first, then the
    /// system prompt, so the consent dialog never appears out of nowhere.
    /// It runs on its own so the refresh path never waits on a dialog; one
    /// browser at a time, and a browser that arrives while another is being
    /// asked about is picked up by a later read.
    private func beginGuide(for app: AppInfo) {
        let bundleID = app.bundleID
        guard !declined.contains(bundleID), !prompting, promptsAllowed() else { return }
        prompting = true
        Task { [self] in
            defer { prompting = false }
            guard await guide(app) else {
                declined.insert(bundleID)
                log.notice("automation guide declined bundle=\(bundleID, privacy: .public)")
                return
            }
            let status = await permission.request(for: bundleID)
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
    }

    private func record(_ status: AutomationStatus, for bundleID: String) {
        verdicts[bundleID] = Verdict(status: status, at: .now)
        if status == .authorized {
            deniedBundleIDs.remove(bundleID)
        } else {
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
