import AppKit
import OpenTabCore

/// Offers to move the app into `/Applications` before anything asks for a
/// permission.
///
/// The order matters: a grant given to a copy in `~/Downloads`, or to the
/// temporary read-only copy macOS runs a freshly downloaded app from, is tied
/// to a location that will not be there next launch. The user then sees
/// OpenTab ticked in the Accessibility list and still listing nothing.
@MainActor
enum InstallLocationPrompt {
    /// Written when the user ticks "Don't ask again"; the check is otherwise
    /// made on every launch.
    static let skipCheckDefaultsKey = "install.skipLocationCheck"

    /// Passed to the copy this one starts. Everything below is meant to leave
    /// the app somewhere permanent and not translocated, so a successor that
    /// still is not tells us the fix did not work — and must never start a
    /// third process to try again.
    static let relaunchArgument = "--relaunched-after-install-move"

    private static let quarantineAttribute = "com.apple.quarantine"
    private nonisolated static let log = Log.make("install")
    private static let applications = URL(fileURLWithPath: "/Applications", isDirectory: true)

    /// Returns true when a copy at another location is taking over and this
    /// process must stop launching.
    static func runIfNeeded(defaults: UserDefaults = .standard) -> Bool {
        // The diagnostic run and the app-hosted test host both load this
        // binary without a user in front of it; neither may block on a modal.
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil,
              !CommandLine.arguments.contains("--selftest"),
              !defaults.bool(forKey: skipCheckDefaultsKey) else { return false }

        let bundleURL = Bundle.main.bundleURL
        let action = InstallLocation.action(bundlePath: bundleURL.path, homeDirectory: NSHomeDirectory()) { path in
            guard let original = InstallLocation.originalPath(ofTranslocatedBundle: URL(fileURLWithPath: path)) else {
                log.error("""
                    running translocated and \(InstallLocation.originalPathSymbol, privacy: .public) \
                    is unavailable: cannot offer to move
                    """)
                return nil
            }
            log.notice("running translocated from \(original.path, privacy: .public)")
            return original.path
        }
        let isRetry = CommandLine.arguments.contains(relaunchArgument)

        switch action {
        case .none:
            return false
        case _ where isRetry:
            log.error("still not running from a permanent copy after a relaunch: \(String(describing: action), privacy: .public)")
            explain(defaults: defaults)
            return false
        case .move(let path):
            return offerMove(of: URL(fileURLWithPath: path), defaults: defaults)
        case .relaunch(let path):
            // No question to put: the app is where the user wants it and the
            // only thing wrong is the flag left over from the download.
            let original = URL(fileURLWithPath: path)
            log.notice("already installed at \(path, privacy: .public); clearing quarantine and restarting")
            guard clearQuarantine(at: original) else {
                explain(defaults: defaults)
                return false
            }
            relaunch(from: original)
            return true
        case .explain:
            explain(defaults: defaults)
            return false
        }
    }

    private static func offerMove(of bundleURL: URL, defaults: UserDefaults) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Move OpenTab to the Applications folder?"
        alert.informativeText = """
            OpenTab is running from \(bundleURL.deletingLastPathComponent().path). macOS ties the \
            Accessibility permission to where an app lives, so a copy that is later moved or deleted \
            loses the permission you give it and OpenTab stops listing windows.
            """
        alert.addButton(withTitle: "Move to Applications")
        alert.addButton(withTitle: "Not Now")
        guard runModal(alert, defaults: defaults) == .alertFirstButtonReturn else { return false }
        return move(bundleURL)
    }

    /// The cases the app cannot fix for the user: a read-only copy with no
    /// traceable original, or one that stayed read-only after being moved.
    /// Both are undone by a move made in the Finder, which is the one gesture
    /// that clears the download flag by itself.
    private static func explain(defaults: UserDefaults) {
        let alert = NSAlert()
        alert.messageText = "Move OpenTab to the Applications folder"
        alert.informativeText = """
            macOS is running OpenTab from a temporary read-only copy, which is what it does with a \
            downloaded app that has not been moved in the Finder. That copy is somewhere else on \
            every launch, so an Accessibility permission granted to it never applies again. Quit \
            OpenTab, then in the Finder drag OpenTab.app into your Applications folder — or, if it \
            is already there, drag it out and back in — and open it again.
            """
        alert.addButton(withTitle: "OK")
        _ = runModal(alert, defaults: defaults)
    }

    private static func move(_ bundleURL: URL) -> Bool {
        let destination = applications.appendingPathComponent(bundleURL.lastPathComponent)
        let manager = FileManager.default
        guard !manager.fileExists(atPath: destination.path) else {
            report("""
                There is already an app at \(destination.path), and OpenTab will not replace it. Quit \
                OpenTab, then move OpenTab.app into the Applications folder in the Finder yourself, \
                replacing what is there if that is what you mean to do.
                """)
            return false
        }
        do {
            try manager.moveItem(at: bundleURL, to: destination)
        } catch {
            report("OpenTab could not be moved to \(destination.path).\n\n\(error.localizedDescription)")
            log.error("move to \(destination.path, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            return false
        }
        log.notice("moved to \(destination.path, privacy: .public)")
        clearQuarantine(at: destination)
        relaunch(from: destination)
        return true
    }

    /// Strips the download flag from every file in the bundle.
    ///
    /// A plain move keeps the flag, and while it is set macOS keeps running
    /// the app from a throwaway read-only copy at a fresh path each launch —
    /// exactly what this whole flow exists to escape. Only a move made in the
    /// Finder clears it, so a move made here has to do it explicitly.
    ///
    /// This is not a way around Gatekeeper: it runs after the user has opened
    /// this very copy and let it through, and only on the bundle already
    /// running. It never touches anything the user has not already approved.
    @discardableResult
    private static func clearQuarantine(at url: URL) -> Bool {
        var items = [url]
        if let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil) {
            items.append(contentsOf: enumerator.compactMap { $0 as? URL })
        }
        var cleared = true
        for item in items {
            // Reading errno has to happen next to the call that set it.
            let failure: Int32? = item.withUnsafeFileSystemRepresentation { path in
                guard let path else { return EINVAL }
                // NOFOLLOW: a symlink inside the bundle carries its own flag,
                // and its target may be outside the bundle entirely.
                guard removexattr(path, quarantineAttribute, XATTR_NOFOLLOW) != 0 else { return nil }
                return errno
            }
            // ENOATTR is the answer for every file that never had the flag.
            guard let failure, failure != ENOATTR else { continue }
            cleared = false
            log.error("clearing quarantine on \(item.path, privacy: .public) failed: errno \(failure, privacy: .public)")
        }
        return cleared
    }

    private static func relaunch(from destination: URL) {
        let configuration = NSWorkspace.OpenConfiguration()
        // This process is still registered under the same bundle identifier,
        // so without this the request would be answered by activating it.
        configuration.createsNewApplicationInstance = true
        configuration.arguments = [relaunchArgument]
        NSWorkspace.shared.openApplication(at: destination, configuration: configuration) { _, error in
            if let error {
                log.error("relaunch from \(destination.path, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            }
            Task { @MainActor in NSApp.terminate(nil) }
        }
    }

    /// Every alert that can come back next launch carries the same opt-out: a
    /// user who means to keep the app where it is says so once.
    private static func runModal(_ alert: NSAlert, defaults: UserDefaults) -> NSApplication.ModalResponse {
        alert.alertStyle = .informational
        let dontAsk = NSButton(checkboxWithTitle: "Don't ask again", target: nil, action: nil)
        dontAsk.sizeToFit()
        alert.accessoryView = dontAsk
        NSApp.activate()
        let response = alert.runModal()
        if dontAsk.state == .on { defaults.set(true, forKey: skipCheckDefaultsKey) }
        return response
    }

    /// The outcome of a move the user asked for, so a failure is never
    /// swallowed. No opt-out here: it is not a question that will repeat.
    private static func report(_ text: String) {
        let alert = NSAlert()
        alert.messageText = "OpenTab was not moved"
        alert.informativeText = text
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        NSApp.activate()
        alert.runModal()
    }
}
