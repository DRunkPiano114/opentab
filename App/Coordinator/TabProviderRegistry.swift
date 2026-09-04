import AppKit
import OpenTabAX
import OpenTabCore
import OpenTabScript
import os

/// Which tab provider, if any, reads an app's tabs.
@MainActor
protocol TabProviderLookup: AnyObject {
    func provider(for app: AppInfo) -> (any TabProvider)?
}

/// Safari by bundle id; the Chromium family by probing the running app's
/// scripting definition for the Chromium suite, which also admits forks
/// nobody enumerated. Verdicts are cached per bundle id so a scripting
/// definition is read once per browser.
@MainActor
final class TabProviderRegistry: TabProviderLookup {
    private let engine: AppleScriptEngine
    /// The user's opt-in, which they can change while the app runs. Every
    /// cached verdict is discarded on a change: whether a browser gets a
    /// provider at all depends on it.
    var includesPrivate: Bool {
        didSet {
            guard includesPrivate != oldValue else { return }
            providers.removeAll()
            rejected.removeAll()
        }
    }
    private let accessibility = AXTabProvider()
    private var providers: [String: any TabProvider] = [:]
    private var rejected: Set<String> = []
    private let log = Log.make("providers")

    /// `includesPrivate` is the user's explicit opt-in. Safari cannot
    /// tell private windows apart, so without it Safari contributes no tabs.
    init(engine: AppleScriptEngine, includesPrivate: Bool) {
        self.engine = engine
        self.includesPrivate = includesPrivate
    }

    /// Whether this app's tabs travel over Apple Events, and so needs the
    /// consent step. The Accessibility provider needs none, and putting a
    /// non-browser through the consent flow would be a defect.
    func usesAppleEvents(for app: AppInfo) -> Bool {
        guard let provider = provider(for: app) else { return false }
        return !(provider is any AccessibilityTabReads)
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

    private func make(for app: AppInfo) -> (any TabProvider)? {
        if app.bundleID == SafariTabProvider.safariBundleID {
            // Without the opt-in Safari contributes no tabs at all, so no
            // provider is registered and no Automation consent is requested
            // for it.
            return includesPrivate ? SafariTabProvider(engine: engine, policy: .allTabs) : nil
        }
        if let url = NSRunningApplication(processIdentifier: app.pid)?.bundleURL,
           ChromiumFamily.isChromium(appURL: url) {
            return ChromiumTabProvider(bundleIDs: [app.bundleID], engine: engine,
                                       includesPrivateWindows: includesPrivate)
        }
        // Everything else falls to the Accessibility scan, which covers Finder,
        // terminals and other native tab groups. A browser no scripting
        // dictionary covers is the exception: Accessibility shows a private
        // window's tab titles and offers no reliable way to tell one apart, so
        // such a browser lists windows only unless the user opted in -
        // the same rule Safari already lives under. The Chromium half of that
        // question was settled by the probe above.
        guard accessibility.isAvailable,
              includesPrivate || !Self.namedBrowserBundleIDs.contains(app.bundleID) else { return nil }
        return accessibility
    }

    /// Whether this app can show private windows the Accessibility tree gives
    /// no way to tell apart, and so must not have its tabs read that way.
    ///
    /// Decided by bundle id and by the Chromium scripting-suite probe, which
    /// also catches forks nobody enumerated. Deliberately *not* decided by a
    /// Launch Services URL-scheme registration: every app that can open a link
    /// claims `https`, so iTerm2 and other native tab apps would be silently
    /// demoted to windows only.
    static func isBrowser(_ app: AppInfo, appURL: URL?) -> Bool {
        if namedBrowserBundleIDs.contains(app.bundleID) { return true }
        guard let appURL else { return false }
        return ChromiumFamily.isChromium(appURL: appURL)
    }

    /// Safari, plus the browsers whose engine offers no probe of its own. The
    /// Chromium family is not listed: `ChromiumFamily.isChromium` decides it.
    static let namedBrowserBundleIDs: Set<String> = [
        SafariTabProvider.safariBundleID,
        "com.apple.SafariTechnologyPreview",
        "org.mozilla.firefox",
        "org.mozilla.firefoxdeveloperedition",
        "org.mozilla.nightly",
        "org.torproject.torbrowser",
        "net.waterfox.waterfox",
        "io.gitlab.librewolf-community.librewolf.macos",
        "app.zen-browser.zen",
        "company.thebrowser.Browser",
        "com.kagi.kagimacOS",
    ]
}
