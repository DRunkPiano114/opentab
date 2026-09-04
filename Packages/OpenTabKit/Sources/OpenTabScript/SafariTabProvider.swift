import Foundation
import os
import OpenTabCore

/// Safari's dictionary has no private-browsing flag: `sdef /Applications/Safari.app`
/// exposes `current tab` and the tab's `name` / `index` / `URL` / `visible`, and
/// nothing that separates a private window from a normal one. Reading its tabs
/// therefore means reading private tabs too, which is excluded unless the user
/// opts in, so the default is to contribute no tabs at all and let Safari
/// appear as windows only.
public enum SafariTabPolicy: Sendable {
    case windowsOnly
    /// Reads tabs, dropping the windows an Accessibility-side classifier reports
    /// as private. The classifier returns CGWindowIDs; Safari's AppleScript
    /// window id is the CGWindowID, which is what makes the join possible.
    case tabsExcludingPrivate(@Sendable () -> Set<UInt32>)
    /// Explicit user opt-in: every tab, private windows included. Snapshots
    /// cannot be marked private because Safari does not say which ones are.
    case allTabs
}

public final class SafariTabProvider: TabProvider, TabCloser {
    public static let safariBundleID = "com.apple.Safari"

    public let bundleIDs = [SafariTabProvider.safariBundleID]
    /// No tab id exists, so identity is the index and a dragged tab shifts it.
    public let tokenStability = TokenStability.positional

    private let session: BrowserSession
    private let policy: SafariTabPolicy
    private let log = Log.make("script.safari")

    public init(engine: AppleScriptEngine,
                policy: SafariTabPolicy = .windowsOnly,
                liveness: any BrowserLiveness = WorkspaceBrowserLiveness(),
                health: BrowserHealth = BrowserHealth()) {
        self.session = BrowserSession(engine: engine, liveness: liveness, health: health)
        self.policy = policy
    }

    public func readTabs(for app: AppInfo, deadline: ContinuousClock.Instant) async throws -> [TabSnapshot] {
        guard bundleIDs.contains(app.bundleID) else { throw ScriptError.notFound }
        let excluded: Set<UInt32>
        switch policy {
        case .windowsOnly: return []
        case .tabsExcludingPrivate(let classifier): excluded = classifier()
        case .allTabs: excluded = []
        }

        let source = BrowserScripts.safariReadTabs(bundleID: app.bundleID)
        guard let value = try await session.run(source, bundleID: app.bundleID, cacheable: true,
                                                deadline: deadline) else { return [] }

        let windows = BrowserScriptParser.safariWindows(value)
        var snapshots: [TabSnapshot] = []
        for window in windows {
            let key = Self.windowKey(id: window.windowID)
            if case .cg(let cgID) = key, excluded.contains(cgID) { continue }
            for (offset, index) in window.tabIndices.enumerated() {
                snapshots.append(TabSnapshot(windowKey: key,
                                             token: String(index),
                                             title: window.titles[offset],
                                             url: URL(string: window.urls[offset]),
                                             isActive: index == window.activeTabIndex,
                                             isPrivate: false))
            }
        }
        // Titles never reach the log.
        log.debug("safari tabs read: windows=\(windows.count, privacy: .public) tabs=\(snapshots.count, privacy: .public)")
        return snapshots
    }

    public func activate(_ tab: TabSnapshot, deadline: ContinuousClock.Instant) async throws {
        let source = BrowserScripts.safariActivateTab(bundleID: Self.safariBundleID,
                                                      windowID: try Self.windowID(of: tab),
                                                      tabIndex: try Self.tabIndex(of: tab))
        try await send(source, deadline: deadline)
    }

    /// Closes without selecting the tab first.
    public func close(_ tab: TabSnapshot, deadline: ContinuousClock.Instant) async throws {
        let source = BrowserScripts.safariCloseTab(bundleID: Self.safariBundleID,
                                                   windowID: try Self.windowID(of: tab),
                                                   tabIndex: try Self.tabIndex(of: tab))
        try await send(source, deadline: deadline)
    }

    private func send(_ source: String, deadline: ContinuousClock.Instant) async throws {
        // Not cacheable: the window id and tab index are compiled into it.
        guard try await session.run(source, bundleID: Self.safariBundleID, cacheable: false,
                                    deadline: deadline) != nil else {
            throw ScriptError.targetNotRunning
        }
    }

    static func windowKey(id: String) -> WindowKey {
        if let number = UInt32(id) { return .cg(number) }
        return .scripted(bundleID: safariBundleID, token: id)
    }

    /// Safari window ids go into the script unquoted because the dictionary
    /// types them as integers, so a non-numeric id is rejected rather than
    /// interpolated into a source that would not compile.
    private static func windowID(of tab: TabSnapshot) throws -> String {
        switch tab.windowKey {
        case .cg(let number):
            return String(number)
        case .scripted(_, let token):
            guard UInt32(token) != nil else { throw ScriptError.notFound }
            return token
        case .ax:
            throw ScriptError.notFound
        }
    }

    private static func tabIndex(of tab: TabSnapshot) throws -> Int {
        guard let index = Int(tab.token), index > 0 else { throw ScriptError.notFound }
        return index
    }
}
