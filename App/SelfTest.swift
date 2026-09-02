import AppKit
import ApplicationServices
import OpenTabAX
import OpenTabCore

/// `--selftest --out <dir>` diagnostic run. Results go to `<dir>/selftest.txt`
/// because an app launched through `open` has no stdout. No window titles are
/// written (L16).
@MainActor
enum SelfTest {
    static func outputDirectory(from arguments: [String]) -> URL? {
        guard arguments.contains("--selftest") else { return nil }
        if let i = arguments.firstIndex(of: "--out"), i + 1 < arguments.count {
            return URL(fileURLWithPath: arguments[i + 1], isDirectory: true)
        }
        return URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
    }

    static func run(outputDirectory: URL) async {
        var lines: [String] = []
        let trusted = AXTrust.isTrusted
        lines.append("bundle=\(Bundle.main.bundleIdentifier ?? "nil") path=\(Bundle.main.bundlePath)")
        lines.append("axTrusted=\(trusted)")

        let source = AXWindowSource()
        lines.append("windowIDBridgeAvailable=\(source.isWindowIDBridgeAvailable)")

        let frontmostBefore = NSWorkspace.shared.frontmostApplication
        lines.append(contentsOf: measurePanel())
        lines.append(contentsOf: focusCheck(frontmostBefore: frontmostBefore, trusted: trusted))

        if trusted {
            let directory = WorkspaceAppDirectory()
            let apps = directory.runningApps()
            let report = await source.measure(apps: apps)
            lines.append(report.text)
        } else {
            lines.append("enumeration skipped: Accessibility not granted (grant ~/Applications/OpenTab.app and rerun)")
        }

        let text = lines.joined(separator: "\n") + "\n"
        do {
            try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
            try Data(text.utf8).write(to: outputDirectory.appendingPathComponent("selftest.txt"), options: .atomic)
        } catch {
            Log.make("selftest").error("write failed: \(String(describing: error), privacy: .public)")
        }
        NSApp.terminate(nil)
    }

    /// Cold show (no pre-warm) versus a second show after the first has warmed
    /// SwiftUI's layout, then a pre-warmed controller, to reproduce the
    /// 43.6ms → 2.2ms measurement from the appendix.
    private static func measurePanel() -> [String] {
        let rows = PanelViewModel.Row.placeholders(count: 30)
        var lines: [String] = []

        let cold = PanelController(model: PanelViewModel())
        cold.show(rows: rows, selectedIndex: 1)
        lines.append("panelShowCold=\(format(cold.lastShowDuration))")
        cold.hide()
        cold.show(rows: rows, selectedIndex: 1)
        lines.append("panelShowSecond=\(format(cold.lastShowDuration))")
        cold.hide()

        let warmed = PanelController(model: PanelViewModel())
        warmed.prewarm()
        warmed.show(rows: rows, selectedIndex: 1)
        lines.append("panelShowPrewarmed=\(format(warmed.lastShowDuration))")
        lines.append("panelVisible=\(warmed.panel.isVisible) appActive=\(NSApp.isActive) panelIsKey=\(warmed.panel.isKeyWindow)")
        warmed.hide()
        return lines
    }

    /// The panel must not take focus (L2: judged by observable behaviour). With
    /// the grant, the previously frontmost app's own `kAXFrontmostAttribute` is
    /// the strongest available signal; without it only NSWorkspace is available.
    private static func focusCheck(frontmostBefore: NSRunningApplication?, trusted: Bool) -> [String] {
        var lines: [String] = []
        let after = NSWorkspace.shared.frontmostApplication
        lines.append("frontmostBefore=\(frontmostBefore?.bundleIdentifier ?? "nil") frontmostAfterPanel=\(after?.bundleIdentifier ?? "nil")")
        guard trusted, let before = frontmostBefore else { return lines }
        let element = AXUIElementCreateApplication(before.processIdentifier)
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, kAXFrontmostAttribute as CFString, &value)
        lines.append("previousAppAXFrontmost=\(String(describing: value as? Bool)) error=\(error.rawValue)")
        return lines
    }

    private static func format(_ duration: Duration?) -> String {
        guard let duration else { return "n/a" }
        let ms = Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
        return String(format: "%.2fms", ms)
    }
}
