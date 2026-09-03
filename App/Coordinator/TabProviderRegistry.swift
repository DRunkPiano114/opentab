import AppKit
import OpenTabCore
import OpenTabScript
import os

/// Which tab provider, if any, reads an app's tabs.
@MainActor
protocol TabProviderLookup: AnyObject {
    func provider(for app: AppInfo) -> (any TabProvider)?
    /// The provider's script does not fit this app after all (a fork with a
    /// different dictionary): stop asking.
    func markUnsupported(_ app: AppInfo)
}

/// Safari by bundle id; the Chromium family by probing the running app's
/// scripting definition for the Chromium suite, which also admits forks
/// nobody enumerated. Verdicts are cached per bundle id so a scripting
/// definition is read once per browser.
@MainActor
final class TabProviderRegistry: TabProviderLookup {
    private let engine: AppleScriptEngine
    private let includesPrivate: Bool
    private var providers: [String: any TabProvider] = [:]
    private var rejected: Set<String> = []
    private let log = Log.make("providers")

    /// `includesPrivate` is the user's explicit opt-in (L16). Safari cannot
    /// tell private windows apart, so without it Safari contributes no tabs.
    init(engine: AppleScriptEngine, includesPrivate: Bool) {
        self.engine = engine
        self.includesPrivate = includesPrivate
    }

    func provider(for app: AppInfo) -> (any TabProvider)? {
        let bundleID = app.bundleID
        guard !bundleID.isEmpty, !rejected.contains(bundleID) else { return nil }
        if let known = providers[bundleID] { return known }
        guard let made = make(for: app) else {
            rejected.insert(bundleID)
            return nil
        }
        providers[bundleID] = made
        log.notice("tab provider bundle=\(bundleID, privacy: .public) kind=\(String(describing: type(of: made)), privacy: .public)")
        return made
    }

    func markUnsupported(_ app: AppInfo) {
        guard providers.removeValue(forKey: app.bundleID) != nil else { return }
        rejected.insert(app.bundleID)
        log.error("tab provider withdrawn bundle=\(app.bundleID, privacy: .public)")
    }

    private func make(for app: AppInfo) -> (any TabProvider)? {
        if app.bundleID == SafariTabProvider.safariBundleID {
            // Without the opt-in Safari contributes no tabs at all, so no
            // provider is registered and no Automation consent is requested
            // for it.
            return includesPrivate ? SafariTabProvider(engine: engine, policy: .allTabs) : nil
        }
        guard let url = NSRunningApplication(processIdentifier: app.pid)?.bundleURL,
              ChromiumFamily.isChromium(appURL: url) else { return nil }
        return ChromiumTabProvider(bundleIDs: [app.bundleID], engine: engine,
                                   includesPrivateWindows: includesPrivate)
    }
}
