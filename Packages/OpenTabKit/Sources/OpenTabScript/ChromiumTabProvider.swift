import Foundation
import os
import OpenTabCore

/// Chrome, Edge and every fork that ships the same dictionary. The window's
/// `mode` property ("normal" / "incognito") is a dictionary value, not a
/// displayed string, so branching on it is safe (L3) and makes the L16 exclusion
/// reliable here in a way it is not for Safari.
public final class ChromiumTabProvider: TabProvider, TabCloser {
    public let bundleIDs: [String]
    /// Chromium tabs carry an id that survives reordering.
    public let tokenStability = TokenStability.stable

    static let incognitoMode = "incognito"

    private let session: BrowserSession
    private let includesPrivateWindows: Bool
    private let log = Log.make("script.chromium")

    /// `includesPrivateWindows` is the user's explicit opt-in; the default
    /// withholds every incognito window's tabs and reports the window alone
    /// (L16).
    public init(bundleIDs: [String],
                engine: AppleScriptEngine,
                includesPrivateWindows: Bool = false,
                liveness: any BrowserLiveness = WorkspaceBrowserLiveness(),
                health: BrowserHealth = BrowserHealth()) {
        self.bundleIDs = bundleIDs
        self.session = BrowserSession(engine: engine, liveness: liveness, health: health)
        self.includesPrivateWindows = includesPrivateWindows
    }

    public func readTabs(for app: AppInfo, deadline: ContinuousClock.Instant) async throws -> [TabSnapshot] {
        guard bundleIDs.contains(app.bundleID) else { throw ScriptError.notFound }
        let source = BrowserScripts.chromiumReadTabs(bundleID: app.bundleID)
        guard let value = try await session.run(source, bundleID: app.bundleID, cacheable: true,
                                                deadline: deadline) else { return [] }

        let windows = BrowserScriptParser.chromiumWindows(value)
        var snapshots: [TabSnapshot] = []
        var withheld = 0
        for window in windows {
            let isPrivate = window.mode == Self.incognitoMode
            let key = WindowKey.scripted(bundleID: app.bundleID, token: window.windowID)
            if isPrivate && !includesPrivateWindows {
                withheld += 1
                // Dropping the tabs is not enough on its own: Accessibility
                // enumerates the window anyway, so the window would still be
                // listed under its own title. The window is reported with its
                // tabs withheld so the reconciler can suppress that row.
                snapshots.append(TabSnapshot(windowKey: key, token: "", title: Self.windowTitle(of: window),
                                             url: nil, isActive: false, isPrivate: true, withholdsTabs: true))
                continue
            }
            for (offset, id) in window.tabIDs.enumerated() {
                snapshots.append(TabSnapshot(windowKey: key,
                                             token: id,
                                             title: window.titles[offset],
                                             url: URL(string: window.urls[offset]),
                                             isActive: offset + 1 == window.activeTabIndex,
                                             isPrivate: isPrivate))
            }
        }
        log.debug("""
            chromium tabs read: windows=\(windows.count, privacy: .public) \
            tabs=\(snapshots.count - withheld, privacy: .public) \
            privateWindowsWithheld=\(withheld, privacy: .public)
            """)
        return snapshots
    }

    /// A Chromium window is titled after its active tab, so the row already
    /// read holds the window's own title; `name of window` would be a second
    /// Apple Event for the same string.
    private static func windowTitle(of window: ChromiumWindowRow) -> String {
        let index = window.activeTabIndex - 1
        guard window.titles.indices.contains(index) else { return window.titles.first ?? "" }
        return window.titles[index]
    }

    public func activate(_ tab: TabSnapshot, deadline: ContinuousClock.Instant) async throws {
        let (bundleID, windowID) = try Self.target(of: tab)
        try await send(BrowserScripts.chromiumActivateTab(bundleID: bundleID, windowID: windowID,
                                                          tabID: tab.token),
                       bundleID: bundleID, deadline: deadline)
    }

    /// Closes without selecting the tab first.
    public func close(_ tab: TabSnapshot, deadline: ContinuousClock.Instant) async throws {
        let (bundleID, windowID) = try Self.target(of: tab)
        try await send(BrowserScripts.chromiumCloseTab(bundleID: bundleID, windowID: windowID,
                                                       tabID: tab.token),
                       bundleID: bundleID, deadline: deadline)
    }

    private func send(_ source: String, bundleID: String,
                      deadline: ContinuousClock.Instant) async throws {
        // Not cacheable: the window and tab ids are compiled into it.
        guard let value = try await session.run(source, bundleID: bundleID, cacheable: false,
                                                deadline: deadline) else {
            throw ScriptError.targetNotRunning
        }
        // The script reports whether it found the window and tab at all.
        if value.string?.lowercased() == "false" { throw ScriptError.notFound }
    }

    private static func target(of tab: TabSnapshot) throws -> (bundleID: String, windowID: String) {
        guard case .scripted(let bundleID, let windowID) = tab.windowKey else {
            throw ScriptError.notFound
        }
        return (bundleID, windowID)
    }
}
