import ApplicationServices
import CoreGraphics
import Foundation

/// Lists running apps with both window counts: what AX reports and what the
/// WindowServer reports. The two disagreeing is itself a finding.
enum CommandList {
    static func run(output: Output) throws -> Int32 {
        let windowsByPID = Dictionary(grouping: CGWindowRow.list([.optionAll, .excludeDesktopElements]),
                                      by: \.pid)
        let onScreenByPID = Dictionary(grouping: CGWindowRow.list([.optionOnScreenOnly, .excludeDesktopElements]),
                                       by: \.pid)

        var rows: [JSON] = []
        var lines = [
            "axprobe list — \(Targets.running().count) running processes (self excluded)",
            "",
            "  " + "PID".padded(7) + " " + "BUNDLE ID".padded(38) + " "
                + "NAME".padded(26) + " " + "AX".padded(5) + " "
                + "CG0".padded(5) + " " + "SCR".padded(5),
        ]

        for target in Targets.running() {
            let (axCount, axError) = AXRead.count(target.element, kAXWindowsAttribute)
            let cgLayer0 = (windowsByPID[target.pid] ?? []).filter { $0.layer == 0 }.count
            let onScreen = (onScreenByPID[target.pid] ?? []).filter { $0.layer == 0 }.count

            var row: [String: JSON] = [:]
            row["pid"] = .int(Int(target.pid))
            row["bundleIdentifier"] = .string(target.bundleIdentifier)
            row["name"] = .string(target.name)
            row["bundlePath"] = .string(target.bundleURL?.path)
            row["activationPolicy"] = .string(target.activationPolicy)
            row["axWindowCount"] = axError == .success ? .int(axCount) : .null
            row["axWindowError"] = .string(axErrorName(axError))
            row["cgLayer0WindowCount"] = .int(cgLayer0)
            row["cgOnScreenWindowCount"] = .int(onScreen)
            rows.append(.object(row))

            let axText = axError == .success ? String(axCount) : "err"
            lines.append("  " + String(target.pid).padded(7) + " "
                + (target.bundleIdentifier ?? "-").padded(38) + " "
                + target.name.padded(26) + " "
                + axText.padded(5) + " "
                + String(cgLayer0).padded(5) + " "
                + String(onScreen).padded(5))
        }

        let trusted = AXIsProcessTrusted()
        lines.append("")
        lines.append("  AX  = kAXWindows count   CG0 = CGWindowList layer-0 (all Spaces)   SCR = on screen now")
        if !trusted {
            lines.append("")
            lines.append("NOT TRUSTED: every AX column is an error. Run `make doctor` for the grant steps.")
        }

        let json = JSON.object([
            "command": .string("list"),
            "axIsProcessTrusted": .bool(trusted),
            "applications": .array(rows),
        ])
        try output.write("list", json: json, summary: lines.joined(separator: "\n"))
        return trusted ? 0 : 2
    }
}

extension String {
    /// Truncate-or-pad so the fixed-width summary table stays aligned.
    fileprivate func padded(_ width: Int) -> String {
        count > width ? String(prefix(width - 1)) + "…" : padding(toLength: width, withPad: " ", startingAt: 0)
    }
}
