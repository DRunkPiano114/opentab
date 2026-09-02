import AppKit
import ApplicationServices
import Foundation
import Security

/// Reports whether this process can actually use the Accessibility API, and the
/// signing identity the TCC grant is attached to.
enum CommandDoctor {
    static func run(output: Output) throws -> Int32 {
        let trusted = AXIsProcessTrusted()
        let signing = signingInformation()
        let launch = launchContext()
        let probe = functionalProbe()

        let json = JSON.object([
            "command": .string("doctor"),
            "axIsProcessTrusted": .bool(trusted),
            "bundle": .object([
                "identifier": .string(Bundle.main.bundleIdentifier),
                "path": .string(Bundle.main.bundlePath),
                "executablePath": .string(Bundle.main.executablePath),
                "isAppBundle": .bool(Bundle.main.bundlePath.hasSuffix(".app")),
            ]),
            "codeSigning": signing,
            "launch": launch,
            "functionalProbe": probe.json,
        ])

        var lines = ["axprobe doctor", ""]
        lines.append("  AXIsProcessTrusted        : \(trusted)")
        lines.append("  Bundle identifier         : \(Bundle.main.bundleIdentifier ?? "(none)")")
        lines.append("  Bundle path               : \(Bundle.main.bundlePath)")
        if case .object(let fields) = signing {
            lines.append("  Signing identifier        : \(text(fields["identifier"]))")
            lines.append("  Designated requirement    : \(text(fields["designatedRequirement"]))")
            lines.append("  cdhash                    : \(text(fields["cdhash"]))")
            lines.append("  Signature flags           : \(text(fields["flags"]))")
        }
        if case .object(let fields) = launch {
            lines.append("  Parent process            : \(text(fields["parentName"])) (pid \(text(fields["parentPID"])))")
        }
        lines.append("  Live AX probe             : \(probe.summary)")
        lines.append("")

        if trusted {
            lines.append("STATUS: trusted. `axprobe list`, `dump`, `tabs` and `spaces` will return real data.")
            if launchLooksInherited() {
                lines.append("")
                lines.append("WARNING: the parent process looks like a shell or terminal. A binary run")
                lines.append("directly from a granted terminal inherits that terminal's Accessibility")
                lines.append("grant and reports a false positive. Re-run via `open -n -W -a` to be sure.")
            }
        } else {
            lines.append(contentsOf: grantInstructions())
        }

        try output.write("doctor", json: json, summary: lines.joined(separator: "\n"))
        return trusted ? 0 : 2
    }

    static func grantInstructions() -> [String] {
        let path = Bundle.main.bundlePath
        return [
            "STATUS: NOT TRUSTED. Every AX call will return apiDisabled(-25211).",
            "",
            "To grant permission (this is a manual step; it cannot be scripted):",
            "  1. Open System Settings > Privacy & Security > Accessibility.",
            "  2. Click +, press Cmd-Shift-G, and paste this path:",
            "       \(path)",
            "  3. Select AXProbe.app, click Open, and switch its toggle ON.",
            "  4. Re-run `make doctor`. No relaunch or logout is required.",
            "",
            "If the toggle is already ON and this still reports false, the stored code",
            "requirement is stale: remove the row with the - button and add it again,",
            "or run `make reset-perms`.",
        ]
    }

    /// The only trustworthy check is an actual cross-process AX call.
    /// `AXIsProcessTrusted` reads a TCC cache; this reads a real app.
    private static func functionalProbe() -> (json: JSON, summary: String) {
        guard let target = Targets.windowOwners().first(where: {
            $0.bundleIdentifier == "com.apple.finder"
        }) ?? Targets.windowOwners().first(where: { $0.activationPolicy == "regular" }) else {
            return (.object(["status": .string("no target app running")]), "no target app running")
        }
        let (count, error) = AXRead.count(target.element, kAXWindowsAttribute)
        let json = JSON.object([
            "target": target.json,
            "attribute": .string(kAXWindowsAttribute),
            "error": .string(axErrorName(error)),
            "windowCount": error == .success ? .int(count) : .null,
        ])
        let summary = error == .success
            ? "\(target.label) kAXWindows -> \(count) window(s)"
            : "\(target.label) kAXWindows -> \(axErrorName(error))"
        return (json, summary)
    }

    private static func signingInformation() -> JSON {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else {
            return .object(["error": .string("SecCodeCopySelf failed")])
        }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else {
            return .object(["error": .string("SecCodeCopyStaticCode failed")])
        }

        var fields: [String: JSON] = [:]

        var requirement: SecRequirement?
        if SecCodeCopyDesignatedRequirement(staticCode, [], &requirement) == errSecSuccess,
           let requirement {
            var text: CFString?
            if SecRequirementCopyString(requirement, [], &text) == errSecSuccess, let text {
                fields["designatedRequirement"] = .string(text as String)
            }
        }

        let flags = SecCSFlags(rawValue: kSecCSSigningInformation | kSecCSRequirementInformation)
        var information: CFDictionary?
        if SecCodeCopySigningInformation(staticCode, flags, &information) == errSecSuccess,
           let dictionary = information as? [String: Any] {
            fields["identifier"] = .string(dictionary[kSecCodeInfoIdentifier as String] as? String)
            fields["teamIdentifier"] = .string(dictionary[kSecCodeInfoTeamIdentifier as String] as? String)
            if let hash = dictionary[kSecCodeInfoUnique as String] as? Data {
                fields["cdhash"] = .string(hash.map { String(format: "%02x", $0) }.joined())
            }
            if let value = dictionary[kSecCodeInfoFlags as String] as? UInt32 {
                fields["flags"] = .string(describeSignatureFlags(value))
            }
        }

        if fields["designatedRequirement"] == nil {
            fields["warning"] = .string("no designated requirement; the binary may be unsigned")
        } else if case .string(let requirement)? = fields["designatedRequirement"],
                  requirement.contains("cdhash") {
            fields["warning"] = .string(
                "ad-hoc designated requirement (cdhash only) — the TCC grant will break on the next rebuild")
        }
        return .object(fields)
    }

    private static func describeSignatureFlags(_ value: UInt32) -> String {
        var names: [String] = []
        if value & 0x2 != 0 { names.append("adhoc") }
        if value & 0x10000 != 0 { names.append("runtime") }
        if value & 0x800 != 0 { names.append("kill") }
        if value & 0x400 != 0 { names.append("hard") }
        let hex = String(format: "0x%x", value)
        return names.isEmpty ? hex : "\(hex)(\(names.joined(separator: ",")))"
    }

    private static func launchContext() -> JSON {
        let parentPID = getppid()
        return .object([
            "pid": .int(Int(getpid())),
            "parentPID": .int(Int(parentPID)),
            "parentName": .string(processName(parentPID)),
            "parentPath": .string(processPath(parentPID)),
        ])
    }

    private static func launchLooksInherited() -> Bool {
        let shells = ["zsh", "bash", "sh", "fish", "login", "Terminal", "iTerm2", "node", "Code", "Cursor"]
        guard let name = processName(getppid()) else { return false }
        return shells.contains(name)
    }

    private static func processPath(_ pid: pid_t) -> String? {
        var buffer = [UInt8](repeating: 0, count: 4096)
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(decoding: buffer[0..<Int(length)], as: UTF8.self)
    }

    private static func processName(_ pid: pid_t) -> String? {
        processPath(pid).map { URL(fileURLWithPath: $0).lastPathComponent }
    }

    private static func text(_ value: JSON?) -> String {
        if case .string(let string)? = value { return string }
        if case .int(let number)? = value { return String(number) }
        return "(none)"
    }
}
