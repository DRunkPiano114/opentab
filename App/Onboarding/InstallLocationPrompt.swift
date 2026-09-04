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

    private nonisolated static let log = Log.make("install")
    private static let applications = URL(fileURLWithPath: "/Applications", isDirectory: true)

    /// Returns true when a copy at the new location is taking over and this
    /// process must stop launching.
    static func runIfNeeded(defaults: UserDefaults = .standard) -> Bool {
        // The diagnostic run and the app-hosted test host both load this
        // binary without a user in front of it; neither may block on a modal.
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil,
              !CommandLine.arguments.contains("--selftest"),
              !defaults.bool(forKey: skipCheckDefaultsKey) else { return false }

        let bundleURL = Bundle.main.bundleURL
        switch InstallLocation.placement(ofBundlePath: bundleURL.path, homeDirectory: NSHomeDirectory()) {
        case .applications:
            return false
        case .elsewhere:
            return offerMove(of: bundleURL, defaults: defaults)
        case .translocated:
            guard let original = InstallLocation.originalPath(ofTranslocatedBundle: bundleURL) else {
                log.error("""
                    running translocated and \(InstallLocation.originalPathSymbol, privacy: .public) \
                    is unavailable: cannot offer to move
                    """)
                explainTranslocation(defaults: defaults)
                return false
            }
            log.notice("running translocated from \(original.path, privacy: .public)")
            return offerMove(of: original, defaults: defaults)
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

    /// Without the original path there is nothing to move: the bundle this
    /// process is running from is a read-only copy, and deleting or rewriting
    /// it would not touch what the user downloaded.
    private static func explainTranslocation(defaults: UserDefaults) {
        let alert = NSAlert()
        alert.messageText = "Move OpenTab to the Applications folder"
        alert.informativeText = """
            macOS is running OpenTab from a temporary read-only copy, which is what it does with a \
            downloaded app opened from the folder it was unzipped in. That copy is somewhere else on \
            every launch, so an Accessibility permission granted to it never applies again. Quit \
            OpenTab, drag OpenTab.app into your Applications folder in the Finder, then open it from \
            there.
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
        relaunch(from: destination)
        return true
    }

    private static func relaunch(from destination: URL) {
        let configuration = NSWorkspace.OpenConfiguration()
        // This process is still registered under the same bundle identifier,
        // so without this the request would be answered by activating it.
        configuration.createsNewApplicationInstance = true
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
