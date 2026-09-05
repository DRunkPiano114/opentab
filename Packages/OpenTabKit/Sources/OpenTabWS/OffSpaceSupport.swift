import AppKit
import OpenTabAX
import OpenTabCore
import os

/// The one object the app wires in: the enhanced window source and
/// activator, the Cmd+Tab takeover, launch-time crash recovery, the
/// standalone restore command and the user-visible degradation notice.
@MainActor
public final class OffSpaceSupport {
    public let windowSource: OffSpaceWindowSource
    public let activator: OffSpaceWindowActivator
    public let cmdTab: CmdTabTakeover

    private let defaults: UserDefaults
    private let log = Log.make("ws")

    /// Handles `--restore-cmd-tab`. The caller exits when this returns `true`.
    public static func handleRestoreCommand(arguments: [String], defaults: UserDefaults = .standard) -> Bool {
        guard arguments.contains(CmdTabTakeover.restoreArgument) else { return false }
        _ = CmdTabTakeover.runRestoreCommand(defaults: defaults)
        return true
    }

    public init(base: AXWindowSource, defaults: UserDefaults = .standard, takeoverEnabled: Bool = true) {
        self.defaults = defaults
        CmdTabTakeover.isDisabledForThisProcess = !takeoverEnabled
        for line in OffSpaceDiagnostics.symbolTable() {
            log.notice("symbol \(line, privacy: .public)")
        }
        CmdTabTakeover.restoreIfCrashed(defaults: defaults)

        let configuration = OffSpaceConfiguration.from(defaults)
        windowSource = OffSpaceWindowSource(base: base, configuration: configuration)
        activator = OffSpaceWindowActivator(source: windowSource)
        cmdTab = CmdTabTakeover(defaults: defaults)

        let availability = windowSource.availability
        log.notice("""
            off-space tokenPath=\(availability.tokenPath, privacy: .public) \
            spaceMap=\(availability.spaceMap, privacy: .public) \
            active=\(self.windowSource.isTokenPathActive, privacy: .public) \
            scanMaxElementID=\(configuration.maxElementID, privacy: .public) \
            scanBudget=\(String(describing: configuration.scanBudget), privacy: .public) \
            cmdTabAvailable=\(CmdTabTakeover.isAvailable, privacy: .public) \
            cmdTabConfigured=\(CmdTabTakeover.isConfigured(defaults), privacy: .public)
            """)
        if let summary = availability.userVisibleSummary {
            log.error("degraded: \(summary, privacy: .public)")
        }
    }

    /// A missing symbol is shown to the user, not only logged. Deferred a
    /// turn so the rest of launch is not held behind the modal.
    public func presentDegradationIfNeeded() {
        var messages: [String] = []
        if let summary = windowSource.availability.userVisibleSummary { messages.append(summary) }
        guard !messages.isEmpty else { return }
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = "OpenTab is running with reduced features"
            alert.informativeText = messages.joined(separator: "\n\n")
            alert.alertStyle = .warning
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
    }

    /// `--selftest --out <dir>`: writes `ws-diagnostics.txt` next to the app's
    /// own `selftest.txt`. Needs the Accessibility grant for the per-app part.
    public static func writeDiagnostics(to directory: URL) async {
        // The diagnostic run skips the normal launch path, and a crash marker
        // must be replayed by whichever process comes first.
        CmdTabTakeover.restoreIfCrashed()
        let base = AXWindowSource()
        let source = OffSpaceWindowSource(base: base)
        let apps = AXTrust.isTrusted ? WorkspaceAppDirectory().runningApps() : []
        var text = await OffSpaceDiagnostics.report(source: source, apps: apps)
        if AXTrust.isTrusted {
            text += "\n" + (await OffSpaceDiagnostics.tokenCrossCheck(base: base, apps: apps))
        } else {
            text += "\nper-app reach skipped: Accessibility not granted"
        }
        text += "\ncmdTab available=\(CmdTabTakeover.isAvailable) systemHotKeys=\(SymbolicHotKeys.readEnabled())\n"
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data(text.utf8).write(to: directory.appendingPathComponent("ws-diagnostics.txt"), options: .atomic)
        } catch {
            Log.make("ws").error("diagnostics write failed: \(String(describing: error), privacy: .public)")
        }
    }
}
