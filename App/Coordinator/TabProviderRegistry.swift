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
    private let includesPrivate: Bool
    private let accessibility = AXTabProvider()
    private var providers: [String: any TabProvider] = [:]
    private var rejected: Set<String> = []
    private let log = Log.make("providers")

    /// `includesPrivate` is the user's explicit opt-in (L16). Safari cannot
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
        // Everything else falls to the Accessibility scan, which covers Finder
        // and other native tab groups. A browser no scripting dictionary
        // covers is the exception: Accessibility shows a private window's tab
        // titles and offers no reliable way to tell one apart, so such a
        // browser lists windows only unless the user opted in (L16) - the same
        // rule Safari already lives under.
        guard accessibility.isAvailable, includesPrivate || !Self.isBrowser(app) else { return nil }
        return accessibility
    }

    /// An app registered with Launch Services as an `https` handler. A system
    /// fact, not a display string (L3).
    ///
    /// It over-reaches: a terminal that can open a link (iTerm2 registers the
    /// scheme) is caught too and lists windows only. That is the safe side of
    /// the trade - the alternative is guessing wrong about a browser that has
    /// private windows, and L16 says not to gamble on that.
    private static func isBrowser(_ app: AppInfo) -> Bool {
        guard !app.bundleID.isEmpty else { return false }
        return browserBundleIDs.contains(app.bundleID)
    }

    private static let browserBundleIDs: Set<String> = {
        guard let probe = URL(string: "https://example.invalid") else { return [] }
        return Set(NSWorkspace.shared.urlsForApplications(toOpen: probe)
            .compactMap { Bundle(url: $0)?.bundleIdentifier })
    }()
}
