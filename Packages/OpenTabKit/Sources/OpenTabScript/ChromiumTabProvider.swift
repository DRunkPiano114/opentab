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

    /// `includesPrivateWindows` is the user's explicit opt-in; the default drops
    /// incognito windows entirely (L16).
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
        var droppedPrivate = 0
        for window in windows {
            let isPrivate = window.mode == Self.incognitoMode
            if isPrivate && !includesPrivateWindows {
                droppedPrivate += 1
                continue
            }
            let key = WindowKey.scripted(bundleID: app.bundleID, token: window.windowID)
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
            tabs=\(snapshots.count, privacy: .public) \
            privateWindowsDropped=\(droppedPrivate, privacy: .public)
            """)
        return snapshots
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
